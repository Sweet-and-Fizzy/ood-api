# frozen_string_literal: true

require_relative 'base'
require_relative '../handlers/sessions'
require_relative '../../lib/site_clusters'

module OodApi
  module Tools
    # MCP tool: list the user's interactive app sessions.
    class ListInteractiveSessionsTool < Base
      tool_name 'list_interactive_sessions'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List the user\'s interactive app sessions (such as Jupyter, RStudio or a desktop) as the ' \
                  'Dashboard records them, newest first, with each one\'s app, status and job. The user ' \
                  'connects to, or deletes, a session on the Dashboard page this returns.'
      input_schema({ type: 'object', properties: {} })

      def self.run(**_params)
        sessions = audited('list_interactive_sessions') do
          Handlers::Sessions.list(clusters: SiteClusters.all)
        end
        if sessions.empty?
          return text_response("You have no interactive sessions. Start one from #{Handlers::Sessions::SESSIONS_PAGE}.")
        end

        lines = sessions.map do |s|
          "- #{McpText.safe_text(s.title)} (#{McpText.safe_text(s.app)}): #{s.status}, " \
            "job #{McpText.safe_text(s.job_id)} on #{McpText.safe_text(s.cluster_id)}, created #{s.created_at || 'N/A'}"
        end
        text_response("#{sessions.size} interactive session(s), newest first:\n#{lines.join("\n")}\n" \
                      "Connect to or delete them at #{Handlers::Sessions::SESSIONS_PAGE}")
      end
    end

    # MCP tool: list the interactive apps the site offers.
    class ListInteractiveAppsTool < Base
      tool_name 'list_interactive_apps'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List the interactive apps this site offers (such as Jupyter, RStudio or a desktop), each ' \
                  'with what its form asks for and the Dashboard page where the user starts a session. Use it ' \
                  'when the user wants to start an interactive session: the session is started from that page.'
      input_schema({ type: 'object', properties: {} })

      def self.run(**_params)
        apps = audited('list_interactive_apps') { Handlers::Sessions.apps }
        return text_response('This site offers no interactive apps.') if apps.empty?

        lines = apps.map do |a|
          about = a.description.empty? ? '' : ": #{McpText.safe_text(a.description.lines.first.to_s.strip)}"
          asks = a.fields.empty? ? '' : "\n  its form asks for: #{a.fields.map { |f| McpText.safe_text(f) }.join(', ')}"
          "- #{McpText.safe_text(a.title)} (#{a.token})#{about}#{asks}\n  start it at #{a.launch_page}"
        end
        text_response("Interactive apps:\n#{lines.join("\n")}")
      end
    end
  end
end
