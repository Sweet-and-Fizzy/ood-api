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
    REFRESH_SECONDS = 1
    # A file that mentions one of these holds settings this app acts on.
    OWN_SETTINGS = /\bood_api\b|\ballowlist_path\b/

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
      refresh
      @dashboard_env ||= read_env_file(dashboard_env_file)
    end

    def dashboard_env_file
      Pathname.new(ENV['OOD_DASHBOARD_ENV_FILE'] || '/etc/ood/config/apps/dashboard/env')
    end

    # @return [Hash] the merged contents of the ondemand.d files
    def config
      refresh
      @config ||= read_config
    end

    # @return [Array<String>] files that hold settings for this app and could
    #   not be read. Their contents are unknown, so the app serves nothing
    #   until they are fixed (see OodApi::Capabilities).
    def problems
      config
      @problems || []
    end

    # A setting an admin can give either way: the environment variable when it
    # is set to something, otherwise the key under `ood_api` in ondemand.d. An
    # empty variable counts as unset, so it cannot hide the file's value.
    def setting(env_name, key)
      value = ENV.fetch(env_name, nil)
      return value unless value.nil? || value.strip.empty?

      settings = config[:ood_api]
      settings.is_a?(Hash) ? settings[key] : nil
    end

    # Loads this app's own env file the way the Dashboard loads its own:
    # variables already in the environment win. Called once, before the app
    # is loaded, so a change needs a PUN restart.
    def load_app_env!(file)
      read_env_file(Pathname.new(file)).each { |key, value| ENV[key] ||= value }
    end

    # Run when the files on disk change, with the new settings in place.
    def on_change(&block)
      (@listeners ||= []) << block
    end

    # Forget the cached files.
    def reset!
      @config = nil
      @dashboard_env = nil
      @problems = nil
      @fingerprint = nil
      @checked_at = nil
    end

    # The files are read again when they change, so an admin can turn the app
    # off for every running PUN by editing ondemand.d. Looked at no more than
    # once a second.
    def refresh
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @checked_at && now - @checked_at < REFRESH_SECONDS

      @checked_at = now
      current = fingerprint
      changed = @fingerprint && @fingerprint != current
      @fingerprint = current
      return unless changed

      @dashboard_env = nil
      @config = read_config
      (@listeners || []).each(&:call)
    end

    def fingerprint
      watched = Pathname.glob(config_directory.join('*')) + [dashboard_env_file]
      watched.sort.map do |file|
        stat = file.stat
        [file.to_s, stat.mtime.to_f, stat.size, stat.uid]
      rescue SystemCallError
        [file.to_s]
      end
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
    #
    # The Dashboard skips such files quietly. Here a skipped file is a
    # problem when it holds settings for this app, because what it said is
    # then unknown: it may have been the file that turned something off.
    def read_config
      @problems = []
      config_files.each_with_object({}) do |file, merged|
        unless trusted?(file)
          skipped(file, 'is not owned by root')
          next
        end
        content = ERB.new(file.read(encoding: 'UTF-8'), trim_mode: '-').result
        parsed = YAML.safe_load(content, aliases: true, symbolize_names: true)
        deep_merge!(merged, parsed) if parsed.is_a?(Hash)
      rescue StandardError, ScriptError => e
        # The Dashboard's ERB can call Dashboard code this app does not have.
        skipped(file, "could not be read (#{e.class})")
      end
    end

    def config_files
      Pathname.glob(config_directory.join('*.{yml,yaml,yml.erb,yaml.erb}')).sort
    end

    def trusted?(file)
      return true unless (ENV['RAILS_ENV'] || ENV.fetch('RACK_ENV', nil)) == 'production'

      file.stat.uid.zero?
    end

    def skipped(file, reason)
      ours = holds_own_settings?(file)
      @problems << "#{file.basename} #{reason}" if ours
      warn "ood_api_audit op=site_config status=#{ours ? 'error' : 'skipped'} " \
           "file=#{file.basename} error=\"#{reason}\""
    end

    # A file that cannot be read at all is assumed to.
    def holds_own_settings?(file)
      file.read(encoding: 'UTF-8').scrub.match?(OWN_SETTINGS)
    rescue SystemCallError
      true
    end

    def deep_merge!(base, other)
      base.merge!(other) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge!(old, new) : new
      end
    end
  end
end
