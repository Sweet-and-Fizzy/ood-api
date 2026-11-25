# frozen_string_literal: true

# Constructs the MCP server with all tools and resources.
# Shared between config.ru (Passenger/production) and bin/dev (local development).

require 'mcp'
require 'json'
require 'stringio'
require_relative '../lib/app_auth'
require_relative '../lib/origin_check'
require_relative '../lib/capabilities'
require_relative 'mcp_tools/clusters'
require_relative 'mcp_tools/jobs'
require_relative 'mcp_tools/files'
require_relative 'mcp_tools/env'
require_relative 'mcp_tools/sessions'
require_relative 'mcp_tools/software'
require_relative 'mcp_tools/usage'
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
      OodApi::Log.line "op=mcp_instrumentation_failed status=error error=#{e.class}"
    end
    result
  end
end

# The MCP endpoint: builds the server from the enabled tools and wraps the
# transport with the same request checks the REST API applies.
module OodApi
  MCP_TOOLS = [
    Tools::ListClustersTool, Tools::GetClusterTool, Tools::ListAccountsTool, Tools::ListQueuesTool,
    Tools::GetClusterInfoTool,
    Tools::ListJobsTool, Tools::GetJobTool, Tools::ListHistoricJobsTool, Tools::SubmitJobTool,
    Tools::CancelJobTool, Tools::HoldJobTool, Tools::ReleaseJobTool,
    Tools::ListFilesTool, Tools::FindFilesTool, Tools::ReadFileTool, Tools::WriteFileTool, Tools::CreateDirectoryTool,
    Tools::DeleteFileTool,
    Tools::ListEnvTool, Tools::GetEnvTool,
    Tools::ListInteractiveSessionsTool, Tools::ListInteractiveAppsTool,
    Tools::ListSoftwareTool, Tools::GetQuotaAndBalanceTool
  ].freeze

  # A tool the site has not turned on is left out of `tools/list` entirely,
  # rather than listed and refused. A model shown a tool that says no will
  # retry it or argue for it; one that is absent is not part of the
  # conversation.
  def self.enabled_mcp_tools
    MCP_TOOLS.select { |tool| Capabilities.enabled?(tool.name_value) }
  end

  # What the server tells a client about itself. It describes only what the
  # site has turned on, so a model is not told about tools it cannot see.
  def self.mcp_instructions
    parts = ['list clusters, discover accounts and queues, check cluster utilization, view jobs and job history, ' \
             'list and read files, and query environment variables']
    parts << 'submit, cancel, hold and release jobs' if Capabilities.enabled?('submit_job')
    parts << 'write files, create directories and delete files' if Capabilities.enabled?('write_file')
    "Open OnDemand HPC cluster tools. Use these tools to #{parts.join('; ')}. " \
      'This site may not have every tool enabled. ' \
      'Read the ood://context resource for site-specific policies before acting.'
  end

  def self.build_mcp_server
    server = MCP::Server.new(
      name:         'ood-api',
      instructions: mcp_instructions,
      tools:        enabled_mcp_tools,
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

  # Body cap for /mcp.
  #
  # The transport defaults to a 4 MiB body cap, but write_file advertises
  # MAX_FILE_WRITE (50 MB by default), so the default would reject a
  # legitimate write before the handler ever saw it. Keep the two limits
  # equal, and let a site that raises OOD_API_MAX_FILE_WRITE raise both.
  #
  # Some headroom on top: the body is a JSON envelope around the content, so
  # escaping (\n, \", non-ASCII) makes the encoded form larger than the file
  # it carries. Without it a file just under the limit could still be
  # refused.
  def self.max_request_bytes
    (Handlers::Files::MAX_FILE_WRITE * 1.5).to_i
  end

  def self.build_mcp_transport(server = build_mcp_server)
    # Stateless mode: each request is independent, no in-memory sessions.
    # Required because OOD's PUN recycles idle Passenger processes
    # (passenger_min_instances 0), which destroys in-memory state.
    # Stateless supports all tool calls and resource reads; the only
    # thing lost is server-initiated notifications (tools/list changed);
    # a client sees a changed tool list the next time it asks.

    # DNS-rebinding protection is off in a PUN and on everywhere else.
    #
    # The gem allows only loopback names by default, which would refuse
    # every request at a real site, where Host is the portal's name. In a
    # PUN it is also redundant: nothing reaches the app except through
    # Apache, which has authenticated the request first.
    #
    # The development server has no Apache and no authentication. There the
    # check is what stops a page on another site from pointing its own
    # hostname at 127.0.0.1 and calling the tools from the developer's
    # browser.
    #
    # This shipped broken in v0.2.0, switched on everywhere, and went
    # unnoticed because every check ran against localhost, which is inside
    # the gem's default allowlist.
    MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless:                true,
      max_request_bytes:        max_request_bytes,
      dns_rebinding_protection: !SiteConfig.behind_portal?
    )
  end

  JSONRPC_INVALID_REQUEST = -32_600
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

  # Bounded read, before any parse: the transport enforces the same limit, but
  # only after the pre-check had already read and parsed the whole body.
  # Returns nil when the body is over the limit.
  def self.read_bounded_body(request)
    body = request.body.read(max_request_bytes + 1) || ''
    return nil if body.bytesize > max_request_bytes

    # Hand the transport the bytes already read. Rack 3 does not promise a
    # rewindable input, so rewinding the original is not safe.
    request.env['rack.input'] = StringIO.new(body)
    body
  end

  # nil for a body that is not JSON; the transport reports that itself.
  def self.parse_json(body)
    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  # Caller-input shapes that crash the mcp gem one layer below its dispatch,
  # surfacing as -32603 internal errors (or, for a non-object params, an
  # unrescued TypeError → HTTP 500). Catch them here, on the parsed body, and
  # return the JSON-RPC error the lambda should send — or nil to let the
  # request through to the transport.
  def self.precheck_request_body(request)
    return nil unless request.body

    body = read_bounded_body(request)
    return jsonrpc_error(413, 'Request body too large', JSONRPC_INVALID_REQUEST) if body.nil?

    parsed = parse_json(body)
    return nil unless parsed

    return jsonrpc_error(400, 'Method not found', JSONRPC_METHOD_NOT_FOUND) if unsupported_method?(parsed)

    problem = BODY_CHECKS.find { |check, _| send(check, parsed) }&.last
    return jsonrpc_error(400, "Invalid params: #{problem}", JSONRPC_INVALID_PARAMS) if problem

    record_disabled_tool_call(parsed)
    nil
  end

  # A tool the site has switched off is not in the server at all, so the
  # server answers "Tool not found" without the tool ever running. The call
  # is recorded here, as the REST API records a refused route.
  def self.record_disabled_tool_call(parsed)
    return unless parsed.is_a?(Hash) && parsed['method'] == 'tools/call' && parsed['params'].is_a?(Hash)

    name = parsed['params']['name'].to_s
    return unless Capabilities::ALL_TOOLS.include?(name) && !Capabilities.enabled?(name)

    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    Handlers::Audit.emit_event(op: name, user: user, source: 'mcp', status: 'disabled')
  end

  # Each check that refuses a parsed body, with what to tell the client. The
  # first that matches wins.
  BODY_CHECKS = [
    [:non_finite_number?,        'a number is not finite'],
    [:malformed_params?,         'params must be an object'],
    [:malformed_tool_arguments?, 'tool arguments must be an object'],
    [:malformed_tool_meta?,      '_meta must be an object']
  ].freeze

  def self.jsonrpc_error(status, message, code = JSONRPC_INTERNAL_ERROR)
    [status,
     { 'Content-Type' => 'application/json' },
     [{ jsonrpc: '2.0', id: nil,
        error: { code: code, message: message } }.to_json]]
  end

  def self.refusal(status, error, message)
    [status, { 'Content-Type' => 'application/json' }, [{ error: error, message: message }.to_json]]
  end

  # The checks the REST app runs in its `before` filters. Returns a Rack
  # response to send, or nil to let the request through.
  def self.refuse_request(env)
    unless Capabilities.mcp?
      if Capabilities.problems.any?
        return refusal(503, 'misconfigured',
                       "The MCP endpoint is off because this site's settings could not be understood")
      end
      return refusal(404, 'not_found', 'The MCP endpoint is not enabled at this site')
    end

    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    Handlers::Audit.context = nil
    token = OodApi::AppAuth.authenticate(env)
    if token == false
      # Recorded for the same reason as the REST filter: this is the surface
      # an agent drives, so a refused token must leave a trace. The token
      # value is never logged.
      Handlers::Audit.emit_event(op: 'authenticate', user: user, source: 'mcp',
                                 status: 'denied', path: env['PATH_INFO'].to_s)
      return refusal(401, 'unauthorized', 'Invalid or missing API token')
    end
    Handlers::Audit.context = { token_id: token.id } if token

    # See OodApi::OriginCheck. Every MCP call is a POST, so all are checked.
    return nil unless OodApi::OriginCheck.cross_site?(env)

    Handlers::Audit.emit_event(op: 'origin_check', user: user, source: 'mcp', status: 'denied',
                               origin: env['HTTP_ORIGIN'])
    refusal(403, 'forbidden', 'Cross-site requests are not allowed')
  end

  TRANSPORT_LOCK = Mutex.new

  # The transport for the tools that are on right now. The site's settings
  # can change while the app runs, so the server is rebuilt when the set of
  # enabled tools does; a transport built once at startup would go on
  # listing, and running, tools the site has since switched off.
  def self.current_mcp_transport
    names = Capabilities.enabled_tools.to_a.sort
    TRANSPORT_LOCK.synchronize do
      @mcp_transport = nil unless @mcp_transport_tools == names
      @mcp_transport_tools = names
      @mcp_transport ||= build_mcp_transport
    end
  end

  # @param transport [Object, nil] a fixed transport, for tests; otherwise the
  #   one for the current settings is used on each request
  def self.mcp_rack_app(transport = nil)
    # /mcp is mounted as a sibling Rack app in config.ru, outside the Sinatra
    # app and therefore outside its `before` filters. Without this the MCP
    # surface would serve the full toolset with no app-token check while
    # /api/v1/* enforced one — the same capabilities behind weaker auth.
    lambda do |env|
      if (refused = refuse_request(env))
        return refused
      end

      request = Rack::Request.new(env)
      if (bad = precheck_request_body(request))
        return bad
      end

      (transport || current_mcp_transport).handle_request(request)
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
