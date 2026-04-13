# frozen_string_literal: true

require 'mcp'
require_relative '../handlers/audit'
require_relative '../handlers/env'

class ListEnvTool < MCP::Tool
  tool_name 'list_env'
  description 'List allowed environment variables, optionally filtered by prefix'
  input_schema({
    type: 'object',
    properties: {
      prefix: { type: 'string', description: 'Filter variables by this prefix (e.g. SLURM_)' }
    }
  })

  def self.call(server_context:, prefix: nil, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    vars = Handlers::Audit.log(op: 'list_env', user: user, source: 'mcp') do
      Handlers::Env.list(prefix: prefix)
    end
    if vars.empty?
      text = 'No matching environment variables found.'
    else
      lines = vars.map { |name, value| "  #{name}=#{value}" }
      text = "Environment variables (#{vars.size}):\n#{lines.join("\n")}"
    end
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::ForbiddenError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class GetEnvTool < MCP::Tool
  tool_name 'get_env'
  description 'Get the value of a specific environment variable'
  input_schema({
    type: 'object',
    properties: {
      name: { type: 'string', description: 'Environment variable name' }
    },
    required: ['name']
  })

  def self.call(server_context:, name:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    result = Handlers::Audit.log(op: 'get_env', user: user, source: 'mcp') do
      Handlers::Env.get(name: name)
    end
    text = "#{result[:name]}=#{result[:value]}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ForbiddenError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end
