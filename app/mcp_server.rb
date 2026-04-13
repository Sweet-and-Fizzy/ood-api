# frozen_string_literal: true

# Constructs the MCP server with all tools and resources.
# Shared between config.ru (Passenger/production) and bin/dev (local development).

require 'mcp'
require_relative 'mcp_tools/clusters'
require_relative 'mcp_tools/jobs'
require_relative 'mcp_tools/files'
require_relative 'mcp_tools/env'
require_relative 'mcp_tools/context'
require_relative 'handlers/audit'
require_relative 'handlers/context'

MCP.configure do |config|
  config.instrumentation_callback = lambda do |data|
    if data[:method] == 'initialize' && data[:client]
      user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
      Handlers::Audit.emit_event(
        op: 'mcp_initialize',
        user: user,
        source: 'mcp',
        client: data[:client][:name],
        client_version: data[:client][:version],
        duration: data[:duration]&.round(4)
      )
    end
  end
end

module OodApi
  def self.build_mcp_server
    server = MCP::Server.new(
      name: 'ood-api',
      instructions: 'Open OnDemand HPC cluster management tools. Use these tools to list clusters, view and submit jobs, manage files, and query environment variables.',
      tools: [
        ListClustersTool, GetClusterTool, ListAccountsTool, ListQueuesTool, GetClusterInfoTool,
        ListJobsTool, GetJobTool, ListHistoricJobsTool, SubmitJobTool, CancelJobTool, HoldJobTool, ReleaseJobTool,
        ListFilesTool, ReadFileTool, WriteFileTool, CreateDirectoryTool, DeleteFileTool,
        ListEnvTool, GetEnvTool
      ],
      resources: [CONTEXT_RESOURCE]
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
    MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
  end

  def self.mcp_rack_app(transport = build_mcp_transport)
    ->(env) { transport.handle_request(Rack::Request.new(env)) }
  end
end
