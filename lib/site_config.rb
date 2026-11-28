# frozen_string_literal: true

require 'erb'
require 'pathname'
require 'yaml'
require_relative 'log'

module OodApi
  # Reads what a site has configured.
  #
  # The app's own settings are in its own directory, where Open OnDemand
  # keeps per-app configuration and where nothing in the app's checkout is
  # touched: /etc/ood/config/apps/<app>/config.yml, with environment
  # variables in the `env` file beside it.
  #
  # Three settings belong to the Dashboard and are only followed here: the
  # file allowlist and the download and upload switches. Those are read from
  # where the Dashboard reads them: the environment, the Dashboard's own env
  # file, then /etc/ood/config/ondemand.d.
  module SiteConfig
    ALLOWLIST_KEYS = ['OOD_ALLOWLIST_PATH', 'WHITELIST_PATH'].freeze
    REFRESH_SECONDS = 1
    DEFAULT_ROOT = '/etc/ood/config/apps'
    # The name the install guide uses. Settings left under it are noticed
    # when the app is installed under another name.
    USUAL_NAME = 'ood-api'
    # The settings this app reads from its config.yml.
    OWN_NAMES = [:capabilities, :disable, :rest, :mcp, :local, :app_tokens, :token_max_days, :token_allow_never].freeze
    # A file in ondemand.d that names one of these holds a setting this app
    # follows, so it matters here if that file cannot be read.
    FOLLOWED_SETTINGS = /(?:^|[\s{,])["']?
                         (?:allowlist[_-]?path|shared[_-]?project[_-]?path|download_enabled|upload_enabled|ood[_-]?api)
                         ["']?\s*:/ix
    # Every variable the app reads. Any other OOD_API_ name is a mistake.
    KNOWN_VARIABLES = ['ALLOW_NATIVE', 'ALLOWED_ORIGINS', 'APP_TOKENS', 'CAPABILITIES', 'CONTEXT_PATH', 'DISABLE',
                       'ENV_ALLOWLIST', 'LOCAL', 'MAX_CONTEXT_BYTES', 'MAX_CONTEXT_TOTAL_BYTES', 'MAX_FILE_READ',
                       'MAX_FILE_WRITE', 'MCP', 'REST', 'SYS_APPS', 'TOKEN_ALLOW_NEVER',
                       'TOKEN_MAX_DAYS', 'DEV_BIND', 'CONFIG_ROOT'].map { |name| "OOD_API_#{name}" }.freeze

    module_function

    # Whether the app is running in a PUN, with Open OnDemand's Apache in
    # front of it. Passenger gives the app its URL there. The development
    # server (bin/dev) has neither, and nothing authenticates its requests.
    def behind_portal?
      !ENV.fetch('PASSENGER_BASE_URI', '').strip.empty?
    end

    # The name this app is installed under, which is the name of its
    # directory in /etc/ood/config/apps. Passenger gives the app its URL; in
    # development the checkout's own name stands in.
    def app_name
      @installed_as || File.basename(ENV['PASSENGER_BASE_URI'] || File.expand_path('..', __dir__))
    end

    # Gives the name when there is no Passenger to give it.
    #
    # @param name [String, nil] the directory the app is installed as
    def installed_as!(name)
      @installed_as = name
      reset!
    end

    # Where the site keeps this app's configuration. Worked out once, before
    # the env file there is loaded, so nothing in that file can move it.
    #
    # `OOD_API_CONFIG_ROOT` moves it. The apps that ship with Open OnDemand
    # use `OOD_APP_CONFIG_ROOT`, but each reads that from its own checkout;
    # set for the whole PUN it would move the Dashboard's directory too.
    #
    # @return [Pathname]
    def app_config_root
      @hosted_root || (@app_config_root ||= Pathname.new(given_root || File.join(DEFAULT_ROOT, app_name)))
    end

    # For the Dashboard plugin, which runs this code inside the Dashboard's
    # process to show the token page. The Dashboard has its own URL and its
    # own environment, so it is told where this app's directory is, and the
    # env file is consulted on each lookup because nothing loaded it into
    # that process when it started.
    def hosted_by_dashboard!(root)
      @hosted_root = root && Pathname.new(root)
    end

    # A blank variable is the same as none.
    def given_root
      root = ENV.fetch('OOD_API_CONFIG_ROOT', '').strip
      root.empty? ? nil : root
    end

    # What `/health` and the PUN log say about where the settings came
    # from, so a site that wrote them somewhere else can see that.
    def settings_source
      "#{settings_file} (#{settings_file.exist? ? 'found' : 'not found'})"
    end

    def env_source
      "#{env_file} (#{env_file.exist? ? 'found' : 'not found'})"
    end

    def settings_file
      app_config_root.join('config.yml')
    end

    def env_file
      app_config_root.join('env')
    end

    # @return [Hash] what the site set in the app's config.yml
    def settings
      refresh
      @settings ||= read_settings
    end

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

    # @return [Array<String>] what could not be read or understood. What a
    #   file said is then unknown, so the app serves nothing until it is
    #   fixed (see OodApi::Capabilities).
    def problems
      config
      settings
      (@settings_problems || []) + (@problems || []) + (@env_problems || []) + unknown_variables
    end

    def unknown_variables
      (ENV.keys.grep(/\AOOD_API_/) - KNOWN_VARIABLES).sort.map { |name| "unknown variable #{name}" }
    end

    # A setting an admin can give either way: the environment variable when it
    # is set to something, otherwise the key in the app's config.yml. An
    # empty variable counts as unset, so it cannot hide the file's value.
    def setting(env_name, key)
      value = ENV.fetch(env_name, nil)&.scrub
      value = hosted_env[env_name] if @hosted_root && (value.nil? || value.strip.empty?)
      return value unless value.nil? || value.strip.empty?

      settings[key]
    end

    # The env file as the token page reads it. A file the API itself would
    # refuse to load counts for nothing here either.
    def hosted_env
      file = env_file
      return {} unless file.file? && trusted?(file)

      parse_env(file.read(encoding: 'UTF-8'))
    rescue StandardError
      {}
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

    # Where the Dashboard's Module Browser reads each cluster's list of
    # software modules, looked up where the Dashboard looks: its variable,
    # then the Dashboard's env file, then `module_file_dir` in ondemand.d.
    #
    # @return [Pathname, nil]
    def module_file_dir
      given = [ENV.fetch('OOD_MODULE_FILE_DIR', nil), dashboard_env['OOD_MODULE_FILE_DIR'], config[:module_file_dir]]
      found = given.map { |value| value.to_s.scrub.strip }.find { |value| !value.empty? }
      found && Pathname.new(found)
    end

    # The Dashboard serves no file browser when the Files app is not
    # installed next to it, which is how a site removes file access.
    def files_app_installed?
      apps = sys_apps
      return true unless apps.directory?

      apps.join('files', 'manifest.yml').readable?
    end

    # The Dashboard's Project Manager is served only when its app is
    # installed beside the Dashboard, as the Files app is. Before Open
    # OnDemand 4.0 its projects were laid out differently (scripts, not
    # launchers, and no job log), and that layout is not read, so a
    # Dashboard without launchers counts as having no Project Manager.
    def projects_app_installed?
      apps = sys_apps
      return true unless apps.directory?

      dashboard = apps.join('dashboard')
      return false if dashboard.directory? && !dashboard.join('app', 'models', 'launcher.rb').file?

      apps.join('projects', 'manifest.yml').readable?
    end

    # Where the Dashboard keeps the user's own data: OOD_DATAROOT or
    # RAILS_DATAROOT in the Dashboard's env file, else
    # ~/<portal>/data/sys/dashboard. An OOD_DATAROOT in this app's own
    # environment names this app's data, not the Dashboard's, so it is not
    # read.
    #
    # @return [Pathname]
    def dashboard_data_root
      given = ['OOD_DATAROOT', 'RAILS_DATAROOT'].map { |name| dashboard_env[name] }
      root = given.map { |value| value.to_s.scrub.strip }.find { |value| !value.empty? }
      root ||= "~/#{ENV.fetch('OOD_PORTAL', 'ondemand')}/data/sys/dashboard"
      Pathname.new(File.expand_path(root))
    end

    # The directories the Project Manager offers shared projects from, read
    # where the Dashboard reads them: OOD_SHARED_PROJECT_PATH, then
    # `shared_project_path` in ondemand.d. Colon-separated or a list. As in
    # the Dashboard, a variable set to nothing means no shared locations.
    #
    # @return [Array<Pathname>]
    def shared_project_paths
      given = [ENV.fetch('OOD_SHARED_PROJECT_PATH', nil), dashboard_env['OOD_SHARED_PROJECT_PATH']]
      paths = given.compact.map(&:scrub).first || config.fetch(:shared_project_path, [])
      Array(paths).flat_map { |path| path.to_s.strip.split(':') }.reject(&:empty?).map { |path| Pathname.new(path) }
    end

    # The directory the Dashboard is installed in: the one this app is in,
    # when the Dashboard is beside it, as the Dashboard itself works it out.
    # Only an installed app counts as the Dashboard, so a folder that happens
    # to be named dashboard, such as one in a repository this app is checked
    # out inside, does not.
    def sys_apps(beside = Pathname.new(File.expand_path('../..', __dir__)))
      return Pathname.new(ENV['OOD_API_SYS_APPS']) if ENV['OOD_API_SYS_APPS']

      beside.join('dashboard', 'manifest.yml').file? ? beside : Pathname.new('/var/www/ood/apps/sys')
    end

    # Loads this app's own env file the way the Dashboard loads its own:
    # variables already in the environment win. Called once, before the app
    # is loaded, so a change needs a PUN restart.
    #
    # A file that is there but cannot be read is a problem, not an empty
    # file: it may be where the site required application tokens.
    def load_app_env!(file = env_file)
      app_config_root
      file = Pathname.new(file)
      @env_problems = []
      begin
        # The entry itself, so a link that points nowhere is not mistaken
        # for no file.
        file.lstat
      rescue Errno::ENOENT, Errno::ENOTDIR
        return
      end
      raise ArgumentError, 'not a regular file' unless file.stat.file?
      raise ArgumentError, 'not owned by root, or writable by everyone' unless trusted?(file)

      vars = parse_env(file.read(encoding: 'UTF-8'))
      # The file is found through this setting, so it cannot be set in it.
      if vars.key?('OOD_API_CONFIG_ROOT')
        raise ArgumentError,
              'OOD_API_CONFIG_ROOT cannot be set in the env file it locates'
      end

      vars.each { |key, value| ENV[key] = value if ENV.fetch(key, '').strip.empty? }
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
      @app_config_root = nil
      @settings = nil
      @settings_problems = nil
      @dashboard_env = nil
      @problems = nil
      @fingerprint = nil
      @checked_at = nil
    end

    # The files are read again when they change, so an admin can turn the app
    # off for every running PUN by editing its config.yml. Looked at no more than
    # once a second.
    def refresh
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @checked_at && now - @checked_at < REFRESH_SECONDS

      @checked_at = now
      current = fingerprint
      changed = @fingerprint && @fingerprint != current
      @fingerprint = current
      return unless changed

      # Forgotten, not read again here: each is read when something asks for
      # it, so the token page never evaluates ondemand.d for a lookup that
      # only needs the app's own settings.
      @dashboard_env = nil
      @config = nil
      @settings = nil
      (@listeners || []).each(&:call)
    end

    def fingerprint
      watched = Pathname.glob(config_directory.join('*')) + [dashboard_env_file, settings_file]
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

    # The app's own settings: one plain YAML file. Nothing in it is
    # evaluated. Anything wrong with it is a problem, since what it meant to
    # switch off is then unknown.
    def read_settings
      @settings_problems = misplaced_settings
      file = settings_file
      begin
        # The entry itself: a link that points nowhere is something wrong,
        # not the absence of settings.
        file.lstat
      rescue Errno::ENOENT
        return {}
      end
      load_settings(file)
    rescue StandardError => e
      reason = e.is_a?(ArgumentError) ? e.message : "could not be read (#{e.class})"
      @settings_problems = misplaced_settings + ["#{file.basename} #{reason}"]
      OodApi::Log.line "op=site_config status=error file=#{file.basename} error=\"#{reason}\""
      {}
    end

    # Settings a site wrote where they will not be read: under another
    # spelling of the file's name, or under the usual directory when the app
    # is installed under a different name. Either way the site believes it
    # has restricted something.
    def misplaced_settings
      root = app_config_root
      return ["#{root} is not a directory"] if root.exist? && !root.directory?

      misnamed_settings(root) + settings_under_the_usual_name
    rescue SystemCallError => e
      ["#{app_config_root} could not be read (#{e.class})"]
    end

    def misnamed_settings(root)
      return [] unless root.directory?

      found = root.children.select { |file| file.basename.to_s.match?(/\Aconfig\.ya?ml(\.erb)?\z/i) }
      (found - [settings_file]).map { |file| "settings are read from config.yml, not #{file.basename}" }
    rescue Errno::EACCES
      # A directory users may enter but not list. Its files are still read
      # by name; only this search cannot be made.
      []
    end

    def settings_under_the_usual_name
      usual = Pathname.new(DEFAULT_ROOT).join(USUAL_NAME)
      return [] if usual == app_config_root

      [['config.yml', settings_file], ['env', env_file]].filter_map do |name, read|
        there = usual.join(name)
        next unless there.exist? && !read.exist?

        "#{name} is in #{usual}, but this app is installed as #{app_name} and reads #{read}"
      end
    end

    def load_settings(file)
      raise ArgumentError, 'is not a regular file' unless file.stat.file?
      raise ArgumentError, 'is not owned by root, or is writable by everyone' unless trusted?(file)

      raw = file.binread.force_encoding('UTF-8')
      raise ArgumentError, 'is not valid UTF-8' unless raw.valid_encoding? && !raw.include?("\0")

      documents = Psych.parse_stream(raw).children.select(&:root)
      raise ArgumentError, 'holds more than one YAML document' if documents.size > 1

      checked_settings(YAML.safe_load(raw, aliases: true, symbolize_names: true), documents.first)
    end

    # YAML keeps the last of two equal keys without a word, so a setting
    # written twice is refused rather than guessed at.
    def checked_settings(parsed, document)
      return {} if parsed.nil?
      raise ArgumentError, 'must be a list of settings' unless parsed.is_a?(Hash)

      repeated = keys_of(document.root).tally.find { |_, count| count > 1 }&.first
      raise ArgumentError, "sets #{repeated} more than once" if repeated

      parsed
    end

    # Reads ondemand.d the way the Dashboard does, so both apps see the same
    # allowlist and switches: every file goes through ERB, YAML anchors are
    # allowed, files are merged key by key, and a file that fails is skipped
    # on its own. In production only root-owned files count.
    #
    # The Dashboard skips such files quietly. Here a skipped file is a
    # problem when it names a setting this app follows, because what it said
    # is then unknown.
    def read_config
      @problems = []
      directory = config_directory
      if directory.exist? && !(directory.readable? && directory.executable?)
        @problems << "#{directory} cannot be listed"
      end
      merged = config_files.each_with_object({}) do |file, result|
        parsed = load_file(file)
        deep_merge!(result, parsed) if parsed
      end
      # Never read from there, so a site that put its restrictions there
      # would otherwise have none.
      @problems << "ood_api in #{directory} is not read; put the settings in #{settings_file}" if merged.key?(:ood_api)
      merged
    end

    # @return [Hash, nil] the file's settings, or nil when it is skipped
    def load_file(file)
      return skipped(file, 'is not owned by root, or is writable by everyone') unless trusted?(file)

      content = ERB.new(file.read(encoding: 'UTF-8'), trim_mode: '-').result
      parsed = YAML.safe_load(content, aliases: true, symbolize_names: true)
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError, ScriptError => e
      # The Dashboard's ERB can call Dashboard code this app does not have.
      skipped(file, "could not be read (#{e.class})")
    end

    # The text with comments removed, whole-line and trailing.
    def uncommented(text)
      text.lines.map { |line| line.sub(/(^|\s)#.*/, '') }.join("\n")
    end

    def keys_of(node)
      return [] unless node.is_a?(Psych::Nodes::Mapping)

      node.children.each_slice(2).filter_map { |key, _| key.value if key.respond_to?(:value) }
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
    def skipped(file, reason)
      ours = followed_settings?(file)
      @problems << "#{file.basename} #{reason}" if ours
      OodApi::Log.line "op=site_config status=#{ours ? 'error' : 'skipped'} " \
                       "file=#{file.basename} error=\"#{reason}\""
      nil
    end

    # A file that cannot be read at all is assumed to.
    def followed_settings?(file)
      uncommented(file.binread.scrub).match?(FOLLOWED_SETTINGS)
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
