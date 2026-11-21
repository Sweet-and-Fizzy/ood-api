# frozen_string_literal: true

require 'erb'
require 'pathname'
require 'yaml'

module OodApi
  # Reads the Open OnDemand site settings this app shares with the Dashboard,
  # from the places the Dashboard reads them: the environment, the Dashboard's
  # own env file, then /etc/ood/config/ondemand.d.
  module SiteConfig
    ALLOWLIST_KEYS = ['OOD_ALLOWLIST_PATH', 'WHITELIST_PATH'].freeze

    module_function

    # @return [Pathname] the directory holding the site's ondemand.d files
    def config_directory
      Pathname.new(ENV['OOD_CONFIG_D_DIRECTORY'] || '/etc/ood/config/ondemand.d')
    end

    # The paths the site allows users to browse, as the Dashboard file browser
    # sees them. Empty means the site has not set an allowlist.
    #
    # @return [Array<Pathname>]
    def allowlist_paths
      paths = ALLOWLIST_KEYS.filter_map { |key| ENV[key] || dashboard_env[key] }.first ||
              config.fetch(:allowlist_path, [])
      Array(paths).flat_map { |path| path.to_s.strip.split(':') }
                  .reject(&:empty?)
                  .map { |path| Pathname.new(path).expand_path }
    end

    # Sites usually set the allowlist in the Dashboard's env file, which only
    # the Dashboard process loads. Reading it here is what makes the two apps
    # follow one policy on releases that predate allowlist_path in ondemand.d.
    #
    # @return [Hash{String => String}] the variables set in that file
    def dashboard_env
      @dashboard_env ||= read_env_file(
        Pathname.new(ENV['OOD_DASHBOARD_ENV_FILE'] || '/etc/ood/config/apps/dashboard/env')
      )
    end

    # @return [Hash] the merged contents of the ondemand.d files
    def config
      @config ||= read_config
    end

    # Forget the cached files. For tests, and for nothing else: a PUN picks up
    # a config change when it restarts.
    def reset!
      @config = nil
      @dashboard_env = nil
    end

    # Parses the KEY=value lines of a dotenv file. Quotes around a value are
    # dropped; comments and anything else are ignored.
    def read_env_file(file)
      return {} unless file.file?

      file.each_line(encoding: 'UTF-8').with_object({}) do |line, vars|
        match = line.match(/\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/)
        vars[match[1]] = match[2].sub(/\A(['"])(.*)\1\z/, '\2') if match
      end
    rescue StandardError => e
      warn "ood_api_audit op=site_config status=error error=#{e.class}"
      {}
    end

    # Reads the files the way the Dashboard does, so both apps see the same
    # settings: every file goes through ERB, YAML anchors are allowed, files
    # are merged key by key, and a file that fails is skipped on its own. In
    # production only root-owned files count.
    def read_config
      config_files.each_with_object({}) do |file, merged|
        content = ERB.new(file.read(encoding: 'UTF-8'), trim_mode: '-').result
        parsed = YAML.safe_load(content, aliases: true, symbolize_names: true)
        deep_merge!(merged, parsed) if parsed.is_a?(Hash)
      rescue StandardError, ScriptError => e
        # The Dashboard's ERB can call Dashboard code this app does not have.
        # Such a file is skipped here though the Dashboard reads it, so say
        # which one: a setting in it will not apply to this app.
        warn "ood_api_audit op=site_config status=error file=#{file.basename} error=#{e.class}"
      end
    end

    def config_files
      files = Pathname.glob(config_directory.join('*.{yml,yaml,yml.erb,yaml.erb}')).sort
      return files unless (ENV['RAILS_ENV'] || ENV.fetch('RACK_ENV', nil)) == 'production'

      files.select { |file| file.stat.uid.zero? }
    end

    def deep_merge!(base, other)
      base.merge!(other) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge!(old, new) : new
      end
    end
  end
end
