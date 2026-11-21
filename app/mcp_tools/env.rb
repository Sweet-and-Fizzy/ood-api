# frozen_string_literal: true

require_relative 'base'
require_relative '../handlers/env'

module OodApi
  module Tools
    # MCP tool: list the allowed environment variables.
    class ListEnvTool < Base
      tool_name 'list_env'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List allowed environment variables, optionally filtered by prefix'
      input_schema({
        type:       'object',
        properties: {
          prefix: { type: 'string', description: 'Filter variables by this prefix (e.g. SLURM_)' }
        }
      })

      def self.run(prefix: nil, **_params)
        vars = audited('list_env') do
          Handlers::Env.list(prefix: prefix)
        end
        if vars.empty?
          text = 'No matching environment variables found.'
        else
          lines = vars.map { |name, value| "  #{name}=#{value}" }
          text = "Environment variables (#{vars.size}):\n#{lines.join("\n")}"
        end
        text_response(text)
      end
    end

    # MCP tool: read one allowed environment variable.
    class GetEnvTool < Base
      tool_name 'get_env'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Get the value of a specific environment variable'
      input_schema({
        type:       'object',
        properties: {
          name: { type: 'string', description: 'Environment variable name' }
        },
        required:   ['name']
      })

      def self.run(name:, **_params)
        result = audited('get_env') do
          Handlers::Env.get(name: name)
        end
        text = "#{result[:name]}=#{result[:value]}"
        text_response(text)
      end
    end
  end
end
