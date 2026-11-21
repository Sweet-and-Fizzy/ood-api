# frozen_string_literal: true

require 'erb'
require 'pathname'
require 'yaml'
require_relative 'log'

module OodApi
  # Reads the Open OnDemand site settings this app shares with the Dashboard,
  # from the places the Dashboard reads them: the environment, the Dashboard's
  # own env file, then /etc/ood/config/ondemand.d.
  module SiteConfig
    ALLOWLIST_KEYS = ['OOD_ALLOWLIST_PATH', 'WHITELIST_PATH'].freeze
    REFRESH_SECONDS = 1
    # The settings this app reads from its block in ondemand.d.
    OWN_NAMES = [:capabilities, :disable, :rest, :mcp, :app_tokens, :token_max_days, :token_allow_never].freeze
    # A file that mentions one of these holds settings this app acts on.
    OWN_SETTINGS = /(?:^|[\s{,])["']?(?:ood[_-]?api|allowlist[_-]?path)["']?\s*:/i
    # Every variable the app reads. Any other OOD_API_ name is a mistake.
    KNOWN_VARIABLES = ['ALLOW_NATIVE', 'ALLOWED_ORIGINS', 'APP_TOKENS', 'CAPABILITIES', 'CONTEXT_PATH', 'DISABLE',
                       'ENV_ALLOWLIST', 'ENV_FILE', 'MAX_CONTEXT_BYTES', 'MAX_CONTEXT_TOTAL_BYTES', 'MAX_FILE_READ',
                       'MAX_FILE_WRITE', 'MCP', 'REST', 'SYS_APPS', 'TOKEN_ALLOW_NEVER',
                       'TOKEN_MAX_DAYS', 'DEV_BIND'].map { |name| "OOD_API_#{name}" }.freeze

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
      # A variable set to nothing is not an allowlist, and must not hide one
      # given further down.
      given = ALLOWLIST_KEYS.flat_map { |key| [ENV.fetch(key, nil), dashboard_env[key]] }
      paths = given.compact.map(&:scrub).reject { |value| value.strip.empty? }.first ||
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
      (@problems || []) + (@env_problems || []) + unknown_variables
    end

    def unknown_variables
      (ENV.keys.grep(/\AOOD_API_/) - KNOWN_VARIABLES).sort.map { |name| "unknown variable #{name}" }
    end

    # A setting an admin can give either way: the environment variable when it
    # is set to something, otherwise the key under `ood_api` in ondemand.d. An
    # empty variable counts as unset, so it cannot hide the file's value.
    def setting(env_name, key)
      value = ENV.fetch(env_name, nil)&.scrub
      return value unless value.nil? || value.strip.empty?

      settings = config[:ood_api]
      settings.is_a?(Hash) ? settings[key] : nil
    end

    # A size or count from the environment. Empty, zero or not a number
    # means the default, so a variable left blank cannot set a limit of 0.
    def limit(env_name, default)
      value = Integer(ENV.fetch(env_name, '').strip, 10)
      value.positive? ? value : default
    rescue ArgumentError
      default
    end

    # One of the Dashboard's own on/off settings, read from where the
    # Dashboard reads it: `OOD_<NAME>` in the environment or the Dashboard's
    # env file, then the key in ondemand.d. They default to on. A value that
    # is not plainly "on" counts as off, since these exist to restrict.
    def dashboard_switch?(name)
      env_name = "OOD_#{name.to_s.upcase}"
      value = ENV.fetch(env_name) { dashboard_env.fetch(env_name) { config[name] } }
      value.nil? || ['true', '1', 'yes', 'on'].include?(value.to_s.strip.downcase)
    end

    # The Dashboard serves no file browser when the Files app is not
    # installed next to it, which is how a site removes file access.
    def files_app_installed?
      apps = Pathname.new(ENV['OOD_API_SYS_APPS'] || '/var/www/ood/apps/sys')
      return true unless apps.directory?

      apps.join('files', 'manifest.yml').readable?
    end

    # Loads this app's own env file the way the Dashboard loads its own:
    # variables already in the environment win. Called once, before the app
    # is loaded, so a change needs a PUN restart.
    #
    # A file that is there but cannot be read is a problem, not an empty
    # file: it may be where the site required application tokens.
    def load_app_env!(file)
      file = Pathname.new(file)
      @env_problems = []
      begin
        file.stat
      rescue Errno::ENOENT, Errno::ENOTDIR
        return
      end
      raise ArgumentError, 'not owned by root, or writable by everyone' unless trusted?(file)

      parse_env(file.read(encoding: 'UTF-8')).each do |key, value|
        ENV[key] = value if ENV.fetch(key, '').strip.empty?
      end
    rescue StandardError => e
      @env_problems = ["#{file} could not be used (#{e.message.scrub[0, 80]})"]
      OodApi::Log.line "op=site_config status=error file=#{file.basename} error=#{e.class}"
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
        # ctime as well: unlike mtime it cannot be set back, so a file
        # replaced by one of the same size and date is still noticed.
        [file.to_s, stat.ino, stat.mtime.to_f, stat.ctime.to_f, stat.size, stat.uid]
      rescue SystemCallError
        [file.to_s]
      end
    end

    # Parses the KEY=value lines of a dotenv file. Quotes around a value are
    # dropped; comments and anything else are ignored.
    def read_env_file(file)
      return {} unless file.file?

      parse_env(file.read(encoding: 'UTF-8'))
    rescue StandardError => e
      OodApi::Log.line "op=site_config status=error error=#{e.class}"
      {}
    end

    def parse_env(text)
      raise ArgumentError, 'not valid UTF-8' unless text.valid_encoding?

      text.each_line.with_object({}) do |line, vars|
        match = line.match(/\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*\z/)
        vars[match[1]] = env_value(match[2]) if match
      end
    end

    # A quoted value is taken whole. An unquoted one ends at a comment, as
    # in the dotenv files the Dashboard reads.
    def env_value(raw)
      quoted = raw.match(/\A(['"])(.*)\1\s*(?:#.*)?\z/)
      quoted ? quoted[2] : raw.sub(/\s+#.*\z/, '')
    end

    # Reads the files the way the Dashboard does, so both apps see the same
    # settings: every file goes through ERB, YAML anchors are allowed, files
    # are merged key by key, and a file that fails is skipped on its own. In
    # production only root-owned files count.
    #
    # The Dashboard skips such files quietly. Here a skipped file is a
    # problem when it holds settings for this app, because what it said is
    # then unknown: it may have been the file that turned something off. The
    # same goes for a file that names this app's block in a way that would
    # be silently dropped or overridden.
    def read_config
      @problems = []
      directory = config_directory
      if directory.exist? && !(directory.readable? && directory.executable?)
        @problems << "#{directory} cannot be listed"
      end
      owners = []
      merged = config_files.each_with_object({}) do |file, result|
        parsed = load_file(file)
        next unless parsed

        owners << file.basename.to_s if parsed.key?(:ood_api)
        deep_merge!(result, parsed)
      end
      @problems << "ood_api is set in more than one file: #{owners.join(', ')}" if owners.size > 1
      merged
    end

    # @return [Hash, nil] the file's settings, or nil when it is skipped
    def load_file(file)
      return skipped(file, 'is not owned by root, or is writable by everyone') unless trusted?(file)

      raw = file.binread.force_encoding('UTF-8')
      return skipped(file, 'is not valid UTF-8', ours: true) unless raw.valid_encoding? && !raw.include?("\0")

      content = ERB.new(raw, trim_mode: '-').result
      parsed = YAML.safe_load(content, aliases: true, symbolize_names: true)
      fault = own_settings_fault(content, parsed) || unwrapped_settings(file, parsed)
      return skipped(file, fault, ours: true) if fault

      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError, ScriptError => e
      # The Dashboard's ERB can call Dashboard code this app does not have.
      skipped(file, "could not be read (#{e.class})")
    end

    # What would make this app's settings in a file go missing without an
    # error: YAML keeps only the first document and the last of two equal
    # keys, and a block that is misspelt or nested is just another key.
    def own_settings_fault(content, parsed)
      documents = Psych.parse_stream(content).children.select(&:root)
      return nil unless documents.any? { |document| own_key?(document.root) }
      return 'holds more than one YAML document' if documents.size > 1
      return 'names ood_api, but not as a top-level setting' unless parsed.is_a?(Hash) && parsed.key?(:ood_api)

      repeated_setting(documents.first.root)
    end

    # Whether this app's block is used as a key anywhere in the document,
    # however it is spelt or nested. Looked for in the parsed tree, so a
    # comment or a value that merely contains the name does not count.
    def own_key?(node)
      return false unless node.respond_to?(:children) && node.children

      keys_of(node).any? { |key| key.match?(/\Aood[_-]?api\z/i) } || node.children.any? { |child| own_key?(child) }
    end

    # The text with comments removed, whole-line and trailing.
    def uncommented(text)
      text.lines.map { |line| line.sub(/(^|\s)#.*/, '') }.join("\n")
    end

    # A file named for this app whose settings were written without the
    # `ood_api:` line above them. They would otherwise be ignored.
    def unwrapped_settings(file, parsed)
      return nil unless file.basename.to_s.match?(/ood[_-]?api/i) && parsed.is_a?(Hash) && !parsed.key?(:ood_api)

      stray = parsed.keys & OWN_NAMES
      "sets #{stray.first} at the top level; it belongs under ood_api" unless stray.empty?
    end

    # @return [String, nil] what is set twice, in the file or in the block
    def repeated_setting(root)
      return 'sets ood_api more than once' if keys_of(root).count('ood_api') > 1

      block = root.children.each_slice(2).find { |key, _| scalar(key) == 'ood_api' }&.last
      repeated = keys_of(block).tally.find { |_, count| count > 1 }&.first
      "sets ood_api.#{repeated} more than once" if repeated
    end

    def scalar(node)
      node.value if node.respond_to?(:value)
    end

    def keys_of(node)
      return [] unless node.is_a?(Psych::Nodes::Mapping)

      node.children.each_slice(2).filter_map { |key, _| scalar(key) }
    end

    def config_files
      Pathname.glob(config_directory.join('*.{yml,yaml,yml.erb,yaml.erb}')).sort
    end

    def trusted?(file)
      return true unless (ENV['RAILS_ENV'] || ENV.fetch('RACK_ENV', nil)) == 'production'

      # Root's, and not writable by everyone: anything else could have been
      # put there, or changed, by a user.
      stat = file.stat
      stat.uid.zero? && !stat.world_writable?
    end

    # @return [nil]
    def skipped(file, reason, ours: holds_own_settings?(file))
      @problems << "#{file.basename} #{reason}" if ours
      OodApi::Log.line "op=site_config status=#{ours ? 'error' : 'skipped'} " \
                       "file=#{file.basename} error=\"#{reason}\""
      nil
    end

    # A file that cannot be read at all is assumed to.
    def holds_own_settings?(file)
      uncommented(file.binread.scrub).match?(OWN_SETTINGS)
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
