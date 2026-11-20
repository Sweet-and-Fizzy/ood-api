# frozen_string_literal: true

require 'erb'
require 'pathname'
require 'yaml'

module OodApi
  # Reads the Open OnDemand site settings this app shares with the Dashboard,
  # from the same places and in the same order the Dashboard reads them: an
  # environment variable first, then /etc/ood/config/ondemand.d.
  module SiteConfig
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
      paths = ENV['OOD_ALLOWLIST_PATH'] || ENV['WHITELIST_PATH'] || config.fetch(:allowlist_path, [])
      Array(paths).flat_map { |path| path.to_s.strip.split(':') }
                  .reject(&:empty?)
                  .map { |path| Pathname.new(path).expand_path }
    end

    # @return [Hash] the merged contents of the ondemand.d files
    def config
      @config ||= read_config
    end

    # Forget the cached files. For tests, and for nothing else: a PUN picks up
    # a config change when it restarts.
    def reset!
      @config = nil
    end

    def read_config
      files = Pathname.glob(config_directory.join('*.{yml,yaml,yml.erb,yaml.erb}')).sort
      files.each_with_object({}) do |file, merged|
        content = file.read(encoding: 'UTF-8')
        content = ERB.new(content, trim_mode: '-').result if file.extname == '.erb'
        parsed = YAML.safe_load(content, symbolize_names: true)
        merged.merge!(parsed) if parsed.is_a?(Hash)
      end
    rescue StandardError => e
      # A site config this app cannot read must not take the API down. It is
      # the Dashboard's file first, and the Dashboard reports problems in it.
      warn "ood_api_audit op=site_config status=error error=#{e.class}"
      {}
    end
  end
end
