# frozen_string_literal: true

require_relative 'base'
require_relative 'files'
require_relative '../handlers/projects'
require_relative '../../lib/site_clusters'

module OodApi
  module Tools
    # What the three Project Manager tools say about a list or project that
    # could not be read.
    module ProjectText
      module_function

      def unavailable(error)
        "Your Project Manager projects are unavailable: #{McpText.line(error.message)}. " \
          'This does not mean you have no projects.'
      end
    end

    # MCP tool: list the user's Project Manager projects.
    class ListProjectsTool < Base
      tool_name 'list_projects'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List the user\'s projects in the Dashboard\'s Project Manager, each with its id, name, ' \
                  'directory and Dashboard page. Use get_project for a project\'s launchers and logged jobs.'
      input_schema({ type: 'object', properties: {} })

      def self.run(**_params)
        result = audited('list_projects') { Handlers::Projects.list }
        projects = result[:projects]
        if projects.empty?
          return text_response('You have no projects in the Project Manager. ' \
                               "Create one at #{Handlers::Projects::DASHBOARD}/projects.")
        end

        lines = projects.map do |p|
          "- #{McpText.line(p.name)} (id #{McpText.line(p.id)}): #{about(p)}\n  page #{p.page}"
        end
        more = result[:more].positive? ? "\n#{result[:more]} more not shown." : ''
        text_response("#{projects.size} project(s):\n#{lines.join("\n")}#{more}")
      rescue Handlers::Projects::Unavailable => e
        text_response(ProjectText.unavailable(e))
      end

      def self.about(project)
        return project.problem if project.problem

        where = "in #{McpText.line(project.directory)}"
        project.description.empty? ? where : "#{McpText.line(project.description)}, #{where}"
      end
    end

    # MCP tool: one project's launchers and logged jobs.
    class GetProjectTool < Base
      tool_name 'get_project'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Show one Project Manager project: its launchers, each with its title and the ids of the ' \
                  'fields its form asks for, and the jobs the Project Manager logged for it, newest first. Each ' \
                  'job has the last status the Project Manager saw and its status now from the scheduler. A ' \
                  'launcher\'s defaults and choices are worked out by the Dashboard when its page is shown, so ' \
                  'they are not given here.'
      input_schema({
        type:       'object',
        properties: { project_id: { type: 'string', description: 'The project id, from list_projects' } },
        required:   ['project_id']
      })

      def self.run(project_id:, **_params)
        details = audited('get_project', project_id: project_id) do
          Handlers::Projects.get(project_id, clusters: SiteClusters.all)
        end
        text_response(render(details))
      rescue Handlers::Projects::Unavailable => e
        text_response(ProjectText.unavailable(e))
      end

      def self.render(details)
        p = details.project
        head = "#{McpText.line(p.name)} (id #{McpText.line(p.id)}), page #{p.page}"
        return "#{head}\nThis project is #{McpText.line(p.problem)}." if p.problem

        parts = [head, "Directory: #{McpText.line(p.directory)}"]
        parts << "Description: #{McpText.line(p.description)}" unless p.description.empty?
        parts << launcher_lines(details)
        parts << job_lines(details)
        parts.join("\n")
      end

      def self.launcher_lines(details)
        return "Launchers: unavailable (#{McpText.line(details.launchers_problem)})" if details.launchers_problem
        return 'Launchers: none' if details.launchers.empty?

        lines = details.launchers.map do |l|
          fields = l.fields.empty? ? '' : "; fields #{l.fields.map { |f| McpText.line(f) }.join(', ')}"
          "- #{McpText.line(l.title)} (id #{McpText.line(l.id)})#{fields}"
        end
        "Launchers (open one with open_launcher):\n#{lines.join("\n")}"
      end

      def self.job_lines(details)
        return "Logged jobs: unavailable (#{McpText.line(details.jobs_problem)})" if details.jobs_problem
        return 'Logged jobs: none' if details.jobs.empty?

        lines = details.jobs.map do |j|
          name = j.name.empty? ? '' : " #{McpText.line(j.name)}"
          "- job #{McpText.line(j.id)}#{name} on #{McpText.line(j.cluster_id)}: last known status " \
            "#{McpText.line(j.last_known_status)}, status now #{j.status}, submitted #{j.submitted_at || 'N/A'}"
        end
        more = details.more_jobs.positive? ? "\n#{details.more_jobs} older job(s) not shown." : ''
        "Logged jobs, newest first:\n#{lines.join("\n")}#{more}"
      end
    end

    # MCP tool: the Dashboard page where the user submits a launcher.
    class OpenLauncherTool < Base
      tool_name 'open_launcher'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Give the Dashboard page for one of a project\'s launchers, where the user checks its form ' \
                  'and submits it. This submits nothing: the user presses Launch on that page. Never say a job ' \
                  'was started or submitted because of this tool.'
      input_schema({
        type:       'object',
        properties: {
          project_id:  { type: 'string', description: 'The project id, from list_projects' },
          launcher_id: { type: 'string', description: 'The launcher id, from get_project' }
        },
        required:   ['project_id', 'launcher_id']
      })

      def self.run(project_id:, launcher_id:, **_params)
        project, launcher = audited('open_launcher', project_id: project_id, launcher_id: launcher_id) do
          Handlers::Projects.launcher(project_id, launcher_id)
        end
        text_response("submitted: false\n" \
                      "Launcher #{McpText.line(launcher.title)} in project #{McpText.line(project.name)}: " \
                      "#{launcher.page}\n" \
                      'Nothing was submitted. The user reviews the form on that page and presses Launch to submit it.')
      rescue Handlers::Projects::Unavailable => e
        text_response(ProjectText.unavailable(e))
      end
    end
  end
end
