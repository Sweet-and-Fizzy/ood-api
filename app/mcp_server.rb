# frozen_string_literal: true

# Constructs the MCP server with all tools and resources.
# Shared between config.ru (Passenger/production) and bin/dev (local development).

require 'mcp'
require 'json'
require_relative '../lib/app_auth'
require_relative 'mcp_tools/clusters'
require_relative 'mcp_tools/jobs'
require_relative 'mcp_tools/files'
require_relative 'mcp_tools/env'
require_relative 'mcp_tools/context'
require_relative 'handlers/audit'
require_relative 'handlers/context'

MCP.configure do |config|
  # `around_request` wraps the request; `instrumentation_callback` is
  # soft-deprecated upstream and slated for removal. It must call the block and
  # return its value, and the audit has to run *after* that call — `client` is
  # only added to `data` while the request handler is running.
  #
  # The rescue is not decoration. Upstream invokes this from an `ensure` with
  # no rescue of its own, so a raise here discards an already-successful result
  # and turns it into an error the client cannot get past. `client` is also
  # caller-supplied and need not be a Hash.
  config.around_request = lambda do |data, &request_handler|
    result = request_handler.call
    begin
      client = data[:client]
      if data[:method] == 'initialize' && client.is_a?(Hash)
        user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
        Handlers::Audit.emit_event(
          op:             'mcp_initialize',
          user:           user,
          source:         'mcp',
          client:         client[:name],
          client_version: client[:version],
          duration:       data[:duration]&.round(4)
        )
      end
    rescue StandardError => e
      warn "ood_api_audit op=mcp_instrumentation_failed status=error error=#{e.class}"
    end
    result
  end
end

module OodApi
  def self.build_mcp_server
    server = MCP::Server.new(
      name:         'ood-api',
      instructions: 'Open OnDemand HPC cluster management tools. Use these tools to list clusters, discover accounts and queues, check cluster utilization, submit/cancel/hold/release jobs with optional dependencies, view job history, manage files (read, write, append, create directories, delete), and query environment variables. Read the ood://context resource for site-specific policies before acting.',
      tools:        [
        Tools::ListClustersTool, Tools::GetClusterTool, Tools::ListAccountsTool, Tools::ListQueuesTool,
        Tools::GetClusterInfoTool,
        Tools::ListJobsTool, Tools::GetJobTool, Tools::ListHistoricJobsTool, Tools::SubmitJobTool,
        Tools::CancelJobTool, Tools::HoldJobTool, Tools::ReleaseJobTool,
        Tools::ListFilesTool, Tools::ReadFileTool, Tools::WriteFileTool, Tools::CreateDirectoryTool,
        Tools::DeleteFileTool,
        Tools::ListEnvTool, Tools::GetEnvTool
      ],
      resources:    [Tools::CONTEXT_RESOURCE]
    )

    server.resources_read_handler do |params|
      user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
      case params[:uri]
      when 'ood://context'
        content = Handlers::Audit.log(op: 'read_context', user: user, source: 'mcp', uri: 'ood://context') do
          Handlers::Context.read
        end
        [{ uri: 'ood://context', mimeType: 'text/markdown', text: content }]
      else
        []
      end
    end

    server
  end

  def self.build_mcp_transport(server = build_mcp_server)
    # Stateless mode: each request is independent, no in-memory sessions.
    # Required because OOD's PUN recycles idle Passenger processes
    # (passenger_min_instances 0), which destroys in-memory state.
    # Stateless supports all tool calls and resource reads; the only
    # thing lost is server-initiated notifications (tools/list changed),
    # which we don't use since our tool list is static.
    # The transport defaults to a 4 MiB body cap, but write_file advertises
    # MAX_FILE_WRITE (50 MB by default), so the default would reject a
    # legitimate write before the handler ever saw it. Keep the two limits
    # equal, and let a site that raises OOD_API_MAX_FILE_WRITE raise both.
    #
    # Some headroom on top: the body is a JSON envelope around the content, so
    # escaping (\n, \", non-ASCII) makes the encoded form larger than the file
    # it carries. Without it a file just under the limit could still be
    # refused.
    max_bytes = (Handlers::Files::MAX_FILE_WRITE * 1.5).to_i

    # DNS-rebinding protection off, deliberately. mcp 1.0.0 added it defaulting
    # to on with an allowlist of loopback only, which 403s every request whose
    # Host is a real hostname — that is every OOD site. It is also redundant
    # here: Apache terminates the request, validates Host against the portal's
    # ServerName, and authenticates before anything reaches the PUN. Nothing
    # can address this app except through that proxy.
    #
    # This shipped broken in v0.2.0 and went unnoticed because every check ran
    # against localhost, which is inside the gem's default allowlist.
    MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless:                true,
      max_request_bytes:        max_bytes,
      dns_rebinding_protection: false
    )
  end

  JSONRPC_INTERNAL_ERROR = -32_603
  JSONRPC_INVALID_PARAMS = -32_602
  JSONRPC_METHOD_NOT_FOUND = -32_601

  # JSON has no Infinity literal, but `1e400` overflows to Float::INFINITY when
  # parsed. json_schemer validates an integer-typed parameter by calling
  # Float#floor, which raises FloatDomainError on a non-finite value — so the
  # schema check itself dies before any handler runs, and the app's own numeric
  # guards never get a chance. Refuse the value here, where it is still a
  # client error, rather than reporting it as an internal fault.
  def self.non_finite_number?(value)
    case value
    when Float then !value.finite?
    when Hash then value.any? { |_, v| non_finite_number?(v) }
    when Array then value.any? { |v| non_finite_number?(v) }
    else false
    end
  end

  # Methods whose handler indexes a REQUIRED field out of `params` — tools/call
  # reads `params[:name]`, resources/read reads `params[:uri]` (in this app's
  # own handler). For these, a null or absent params reaches `nil[:field]` and
  # crashes, so params must be a present object, not merely well-shaped when
  # present. Methods that legitimately take no params (ping, tools/list) are
  # not listed.
  METHODS_REQUIRING_PARAMS = ['tools/call', 'resources/read'].freeze

  # The mcp gem's method handlers index `params` directly — `request[:name]`,
  # `request.dig(:_meta, ...)`, `request[:level]` — assuming it is an object.
  # JSON-RPC permits `params` to be an array, and the gem's own param check
  # accepts a missing one, so a request with an array, scalar, or (for the
  # methods above) absent `params` reaches those handlers and raises,
  # surfacing a client mistake as a -32603 internal error. Refuse those shapes
  # here.
  def self.malformed_params?(parsed)
    return false unless parsed.is_a?(Hash) && parsed.key?('method')

    params = parsed['params']

    if METHODS_REQUIRING_PARAMS.include?(parsed['method'])
      # params must be a present object.
      params.nil? || !params.is_a?(Hash)
    else
      # a present params must be an object, but an absent one is fine.
      parsed.key?('params') && !params.nil? && !params.is_a?(Hash)
    end
  end

  # A tools/call whose `arguments` is present but not an object reaches the mcp
  # gem's schema check, which calls `.keys` on it and raises for any tool with
  # a required parameter. Only reached after malformed_params? has confirmed
  # `params` is an object, so the dig here is safe.
  def self.malformed_tool_arguments?(parsed)
    return false unless tools_call_with_object_params?(parsed)

    args = parsed['params']['arguments']
    !args.nil? && !args.is_a?(Hash)
  end

  # `call_tool` also does `request.dig(:_meta, :progressToken)` unconditionally,
  # so a tools/call carrying a `params` object with a non-object `_meta` passes
  # the top-level params check but still crashes the gem — a valid params does
  # not imply a valid `_meta`. Same shape as the arguments guard: the gem
  # indexes a second nested field without checking it.
  def self.malformed_tool_meta?(parsed)
    return false unless tools_call_with_object_params?(parsed)

    meta = parsed['params']['_meta']
    !meta.nil? && !meta.is_a?(Hash)
  end

  def self.tools_call_with_object_params?(parsed)
    parsed.is_a?(Hash) && parsed['method'] == 'tools/call' && parsed['params'].is_a?(Hash)
  end

  # Methods the gem dispatches but this app does not implement — it registers
  # no prompts, no completion, no resource subscriptions, and no log-level
  # handler. The gem answers each with an uncoded capability error that its own
  # mapper turns into -32603 "internal error", when the honest answer is
  # -32601 "method not found". Refuse them here with the right code. An unknown
  # method the gem does not dispatch already returns -32601 on its own.
  UNSUPPORTED_METHODS = [
    'prompts/get', 'prompts/list', 'completion/complete',
    'resources/subscribe', 'resources/unsubscribe', 'logging/setLevel'
  ].freeze

  def self.unsupported_method?(parsed)
    parsed.is_a?(Hash) && UNSUPPORTED_METHODS.include?(parsed['method'])
  end

  # Caller-input shapes that crash the mcp gem one layer below its dispatch,
  # surfacing as -32603 internal errors (or, for a non-object params, an
  # unrescued TypeError → HTTP 500). Catch them here, on the parsed body, and
  # return the JSON-RPC error the lambda should send — or nil to let the
  # request through to the transport.
  def self.precheck_request_body(request)
    body = request.body&.read or return nil
    request.body.rewind
    parsed = begin
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
    return nil unless parsed

    if unsupported_method?(parsed)
      jsonrpc_error(400, 'Method not found', JSONRPC_METHOD_NOT_FOUND)
    elsif non_finite_number?(parsed)
      jsonrpc_error(400, 'Invalid params: a number is not finite', JSONRPC_INVALID_PARAMS)
    elsif malformed_params?(parsed)
      jsonrpc_error(400, 'Invalid params: params must be an object', JSONRPC_INVALID_PARAMS)
    elsif malformed_tool_arguments?(parsed)
      jsonrpc_error(400, 'Invalid params: tool arguments must be an object', JSONRPC_INVALID_PARAMS)
    elsif malformed_tool_meta?(parsed)
      jsonrpc_error(400, 'Invalid params: _meta must be an object', JSONRPC_INVALID_PARAMS)
    end
  end

  def self.jsonrpc_error(status, message, code = JSONRPC_INTERNAL_ERROR)
    [status,
     { 'Content-Type' => 'application/json' },
     [{ jsonrpc: '2.0', id: nil,
        error: { code: code, message: message } }.to_json]]
  end

  def self.mcp_rack_app(transport = build_mcp_transport)
    # /mcp is mounted as a sibling Rack app in config.ru, outside the Sinatra
    # app and therefore outside its `before` filters. Without this the MCP
    # surface would serve the full toolset with no app-token check while
    # /api/v1/* enforced one — the same capabilities behind weaker auth.
    lambda do |env|
      if OodApi::AppAuth.authenticate(env) == false
        # Recorded for the same reason as the REST filter: this is the surface
        # an agent drives, so a refused token must leave a trace. The token
        # value is never logged.
        Handlers::Audit.emit_event(op: 'authenticate', user: ENV['USER'] || ENV['LOGNAME'] || 'unknown', source: 'mcp',
                                   status: 'denied', path: env['PATH_INFO'].to_s)
        return [401,
                { 'Content-Type' => 'application/json' },
                [{ error: 'unauthorized', message: 'Invalid or missing API token' }.to_json]]
      end

      request = Rack::Request.new(env)
      if (bad = precheck_request_body(request))
        return bad
      end

      transport.handle_request(request)
    rescue Interrupt, SystemExit
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      # ScriptError (NotImplementedError, LoadError) is not a StandardError, so
      # neither the gem's handler nor its transport catches it — it escaped to
      # Passenger and killed the worker with a 502. The REST side has an
      # `error ScriptError` handler for exactly this; /mcp had no equivalent.
      Handlers::Audit.emit_event(op: 'mcp_request_failed', user: nil, source: 'mcp', error: e.class.to_s)
      jsonrpc_error(500, "Internal error: #{e.class}")
    end
  end
end
