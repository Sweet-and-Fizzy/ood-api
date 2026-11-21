# frozen_string_literal: true

require 'set'
require 'time'
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

    SETTINGS = SiteConfig::OWN_NAMES
    ON = ['true', '1', 'yes', 'on'].freeze
    OFF = ['false', '0', 'no', 'off'].freeze

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
      resolved[:rest]
    end

    # @return [Boolean] whether /mcp is served at all
    def mcp?
      resolved[:mcp]
    end

    # @return [Array<String>] what is wrong with the site's settings, if anything
    def problems
      resolved[:problems]
    end

    # One line for the PUN log, so an admin can see what their settings produced.
    def summary
      "rest=#{rest?} mcp=#{mcp?} app_tokens=#{AppAuth.enabled?} tools=#{enabled_tools.to_a.sort.join(',')}"
    end

    # Writes the settings in force to the PUN log: at startup, and again
    # whenever the files in ondemand.d change.
    def announce
      found = problems
      found.each { |problem| warn "ood_api_audit op=capabilities status=error error=\"#{problem.tr('"', "'")}\"" }
      note = found.empty? ? '' : ' error="settings could not be understood; nothing is served until they are fixed"'
      warn "ood_api_audit ts=#{Time.now.utc.iso8601(3)} op=capabilities " \
           "status=#{found.empty? ? 'ok' : 'error'} #{summary}#{note}"
    end

    # Settings that cannot be understood turn everything off. A name that is
    # not recognised is never skipped: a typo in `disable`, a misspelt key or
    # `mcp: flase` would otherwise leave on the very thing the site meant to
    # remove, and there is no telling which.
    def resolved
      groups = list_setting('OOD_API_CAPABILITIES', :capabilities) || DEFAULT_GROUPS
      disabled = list_setting('OOD_API_DISABLE', :disable) || []
      rest = switch('OOD_API_REST', :rest)
      mcp = switch('OOD_API_MCP', :mcp)
      problems = setting_problems + [rest, mcp].grep(String) +
                 unknown(groups, GROUPS.keys + ['all'], 'capability') + unknown(disabled, ALL_TOOLS, 'tool')
      return { tools: Set.new, rest: false, mcp: false, problems: problems } unless problems.empty?

      groups = GROUPS.keys if groups.include?('all')
      tools = (['read'] | groups).flat_map { |group| GROUPS.fetch(group) } - disabled - off_in_dashboard
      { tools: Set.new(tools), rest: rest, mcp: mcp, problems: [] }
    end

    # The settings held by an environment variable. One of these cannot be
    # changed from ondemand.d, which matters when a site reaches for the off
    # switch there.
    def from_environment
      SiteConfig::KNOWN_VARIABLES.reject { |name| ENV.fetch(name, '').strip.empty? }.sort
    end

    # What is wrong outside the lists and the two surface switches.
    def setting_problems
      switches = [switch('OOD_API_APP_TOKENS', :app_tokens, default: false),
                  switch('OOD_API_TOKEN_ALLOW_NEVER', :token_allow_never, default: false)]
      SiteConfig.problems + unknown_settings + TokenPolicy.problems + switches.grep(String)
    end

    FILE_TOOLS = ['list_files', 'read_file', 'write_file', 'create_directory', 'delete_file'].freeze

    # What the site has already switched off in the Dashboard's file browser
    # stays off here, whatever `ood_api` asks for: no Files app means no file
    # tools, `download_enabled: false` means file contents cannot be read,
    # and `upload_enabled: false` means they cannot be written.
    def off_in_dashboard
      return FILE_TOOLS unless SiteConfig.files_app_installed?

      off = []
      off << 'read_file' unless SiteConfig.dashboard_switch?(:download_enabled)
      off << 'write_file' unless SiteConfig.dashboard_switch?(:upload_enabled)
      off
    end

    def unknown(names, known, kind)
      (names - known).map { |name| "unknown #{kind} #{name.inspect}" }
    end

    def unknown_settings
      settings = SiteConfig.config[:ood_api]
      return [] if settings.nil?
      return ['ood_api must be a block of settings'] unless settings.is_a?(Hash)

      (settings.keys - SETTINGS).map { |key| "unknown setting ood_api.#{key}" }
    end

    # A comma-separated environment variable, or a list (or comma-separated
    # string) under `ood_api` in ondemand.d. nil when the site set neither.
    def list_setting(env_name, key)
      raw = SiteConfig.setting(env_name, key)
      return nil if raw.nil?

      names = list_from(raw)
      return names unless names.empty? && raw.is_a?(String)

      # A variable holding only commas names nothing, so it does not hide
      # the list in the settings file.
      from_file = site_settings[key]
      list_from(from_file) if from_file
    end

    # @return [Hash] the `ood_api` block from ondemand.d, empty when absent
    def site_settings
      settings = SiteConfig.config[:ood_api]
      settings.is_a?(Hash) ? settings : {}
    end

    # Names are matched whatever their case: `ALL` and `Read_File` are
    # plain enough.
    def list_from(raw)
      Array(raw).flat_map { |item| item.to_s.scrub.split(',') }.map { |name| name.strip.downcase }.reject(&:empty?)
    end

    # @return [Boolean, String] on or off, or what is wrong with the value
    def switch(env_name, key, default: true)
      raw = SiteConfig.setting(env_name, key)
      return default if raw.nil?

      value = raw.to_s.strip.downcase
      return true if ON.include?(value)
      return false if OFF.include?(value)

      "#{key} must be true or false, not #{raw.inspect}"
    end
  end
end

require_relative 'app_auth'
require_relative 'token_policy'

OodApi::SiteConfig.on_change { OodApi::Capabilities.announce }
