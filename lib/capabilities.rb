# frozen_string_literal: true

require 'set'
require_relative 'site_config'

module OodApi
  # Decides which parts of the app a site has turned on.
  #
  # A fresh install is read-only: it can list clusters, jobs and files and
  # read file contents, and nothing else. A site opts in to job submission and
  # file writes, and can remove any single tool by name. The tool name is the
  # key for both surfaces, so disabling `delete_file` removes the MCP tool and
  # refuses `DELETE /api/v1/files` together.
  #
  # Settings come from the environment (`OOD_API_CAPABILITIES`,
  # `OOD_API_DISABLE`, `OOD_API_REST`, `OOD_API_MCP`) or from an `ood_api`
  # block in /etc/ood/config/ondemand.d:
  #
  #   ood_api:
  #     capabilities: [read, jobs, files_write]
  #     disable: [cancel_job]
  #     mcp: false
  module Capabilities
    GROUPS = {
      'read'        => ['list_clusters', 'get_cluster', 'list_accounts', 'list_queues', 'get_cluster_info',
                        'list_jobs', 'get_job', 'list_historic_jobs', 'list_files', 'read_file',
                        'list_env', 'get_env'],
      'jobs'        => ['submit_job', 'cancel_job', 'hold_job', 'release_job'],
      'files_write' => ['write_file', 'create_directory', 'delete_file']
    }.freeze

    ALL_TOOLS = GROUPS.values.flatten.freeze
    DEFAULT_GROUPS = ['read'].freeze

    module_function

    # @return [Set<String>] the names of the tools that are turned on
    def enabled_tools
      resolved[:tools]
    end

    def enabled?(tool_name)
      enabled_tools.include?(tool_name.to_s)
    end

    # @return [Boolean] whether /api/v1 is served at all
    def rest?
      surface?('OOD_API_REST', :rest)
    end

    # @return [Boolean] whether /mcp is served at all
    def mcp?
      surface?('OOD_API_MCP', :mcp)
    end

    # @return [Array<String>] what is wrong with the site's settings, if anything
    def problems
      resolved[:problems]
    end

    # One line for the PUN log, so an admin can see what their settings produced.
    def summary
      "rest=#{rest?} mcp=#{mcp?} tools=#{enabled_tools.to_a.sort.join(',')}"
    end

    # An unknown name is never skipped. A typo in `disable` would otherwise
    # leave the tool it was meant to remove switched on, so settings that do
    # not parse cleanly fall back to read-only and say why.
    def resolved
      groups = list_setting('OOD_API_CAPABILITIES', :capabilities) || DEFAULT_GROUPS
      disabled = list_setting('OOD_API_DISABLE', :disable) || []
      problems = unknown(groups, GROUPS.keys + ['all'], 'capability') + unknown(disabled, ALL_TOOLS, 'tool')
      return { tools: Set.new(GROUPS['read']), problems: problems } unless problems.empty?

      groups = GROUPS.keys if groups.include?('all')
      tools = (['read'] | groups).flat_map { |group| GROUPS.fetch(group) } - disabled
      { tools: Set.new(tools), problems: [] }
    end

    def unknown(names, known, kind)
      (names - known).map { |name| "unknown #{kind} #{name.inspect}" }
    end

    # A comma-separated environment variable, or a list (or comma-separated
    # string) under `ood_api` in ondemand.d. nil when the site set neither.
    def list_setting(env_name, key)
      raw = ENV.fetch(env_name) { site_settings[key] }
      return nil if raw.nil?

      Array(raw).flat_map { |item| item.to_s.split(',') }.map(&:strip).reject(&:empty?)
    end

    def surface?(env_name, key)
      raw = ENV.fetch(env_name) { site_settings[key] }
      raw.nil? || !['false', '0', 'no', 'off'].include?(raw.to_s.strip.downcase)
    end

    def site_settings
      settings = SiteConfig.config[:ood_api]
      settings.is_a?(Hash) ? settings : {}
    end
  end
end
