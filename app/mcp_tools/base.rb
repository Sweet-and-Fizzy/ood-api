# frozen_string_literal: true

require 'mcp'
require_relative '../handlers/audit'
require_relative '../handlers/errors'
require_relative '../../lib/capabilities'

module OodApi
  module Tools
    # Shared behaviour for every MCP tool. A tool declares its schema and
    # implements `run`; this class records the call in the audit log and turns
    # a handler error into a tool error the model can read.
    class Base < MCP::Tool
      class << self
        # Entry point the mcp gem invokes. `server_context` is part of the
        # gem's signature and is not used by these tools.
        #
        # The site's settings are checked on every call, not only when the
        # tool list is built: they can change while the app is running, and a
        # tool switched off since then must stop working at once.
        def call(server_context: nil, **params) # rubocop:disable Lint/UnusedMethodArgument
          return refuse_disabled unless Capabilities.enabled?(name_value)

          run(**params)
        rescue Handlers::Error => e
          error_response(e.message)
        end

        def refuse_disabled
          Handlers::Audit.emit_event(op: name_value, user: current_user, source: 'mcp', status: 'disabled')
          error_response("#{name_value} is not enabled at this site")
        end

        # The PUN runs as the authenticated user, so the OS user is the caller.
        def current_user
          ENV['USER'] || ENV['LOGNAME'] || 'unknown'
        end

        # Runs the block inside an audit record for `operation`.
        def audited(operation, **fields, &)
          Handlers::Audit.log(op: operation, user: current_user, source: 'mcp', **fields, &)
        end

        def text_response(text)
          MCP::Tool::Response.new([{ type: 'text', text: text }])
        end

        def error_response(message)
          MCP::Tool::Response.new([{ type: 'text', text: message }], error: true)
        end
      end
    end
  end
end
