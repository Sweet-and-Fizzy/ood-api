# frozen_string_literal: true

# The token store and policy come from the API this plugin belongs to: the
# checkout the plugin is linked from, or the usual install location when the
# plugin was copied.
api_root = File.expand_path('../..', File.realpath(__dir__))
api_root = '/var/www/ood/apps/sys/ood-api' unless File.file?(File.join(api_root, 'lib', 'api_token.rb'))
require File.join(api_root, 'lib', 'api_token')

# An API token as the Dashboard's token page shows it. Storage, hashing and
# expiry belong to OodApi::ApiToken and OodApi::TokenPolicy; this class adds
# what the page needs: the lifetimes to offer and how to display a token.
class ApiToken
  include ActiveModel::Model

  LIFETIMES = [30, 90, 365].freeze
  DEFAULT_LIFETIME = 90
  NEVER = 'never'
  DAY = 86_400

  attr_reader :id, :name, :token_digest, :created_at, :last_used_at, :expires_at

  class << self
    # The API's directory under /etc/ood/config/apps.
    def app_config_root
      return ENV.fetch('OOD_API_CONFIG_ROOT', nil) unless ENV['OOD_API_CONFIG_ROOT'].to_s.strip.empty?

      # __FILE__ is the path this file was loaded by, with the plugin's link
      # still in it; __dir__ has already followed the link.
      config_root_for(File.expand_path('..', File.dirname(__FILE__)))
    end

    # The directory is named after the directory the API is installed in,
    # which is the name the API is served under. That name is read from the
    # plugin's link, one step and no further. A plugin that is not a link
    # gives no name, so the usual one is assumed.
    #
    # @param plugin [String] the plugin directory as the Dashboard sees it
    def config_root_for(plugin)
      app = 'ood-api'
      if File.symlink?(plugin)
        target = File.expand_path(File.readlink(plugin), File.dirname(plugin))
        app = File.basename(File.dirname(target))
      end
      File.join('/etc/ood/config/apps', app)
    end

    def all
      OodApi::ApiToken.all.map { |token| new(token.to_h) }
    end

    def find(id)
      all.find { |token| token.id == id }
    end

    # @return [Integer] the longest lifetime a token may be given, in days
    def max_days
      OodApi::TokenPolicy.max_days
    end

    def allow_never?
      OodApi::TokenPolicy.allow_never?
    end

    # The lifetimes the form offers: the standard ones the site maximum
    # allows, the maximum itself, and "never" where the site allows it.
    #
    # @return [Array<String>] day counts as strings, and possibly NEVER
    def lifetime_options
      days = (LIFETIMES.select { |lifetime| lifetime <= max_days } | [max_days]).sort
      days.map(&:to_s) + (allow_never? ? [NEVER] : [])
    end

    def default_lifetime
      [DEFAULT_LIFETIME, max_days].min.to_s
    end

    # @param lifetime [String] one of lifetime_options
    # @return [String, nil] an ISO 8601 time, or nil for a token that never expires
    def expiry_for(lifetime)
      return nil if lifetime == NEVER && allow_never?

      days = lifetime_options.include?(lifetime) && lifetime != NEVER ? lifetime.to_i : max_days
      (Time.now + (days * DAY)).iso8601
    end

    # Returns [ApiToken, plain_token]. The plaintext exists only in this return
    # value, for the one page render that shows it to the user.
    def generate(name:, lifetime: default_lifetime)
      token, plain_token = OodApi::ApiToken.create(name: name, expires_at: expiry_for(lifetime))
      [new(token.to_h), plain_token]
    end
  end

  OodApi::SiteConfig.hosted_by_dashboard!(app_config_root)

  def initialize(attrs = {})
    @id           = attrs[:id]
    @name         = attrs[:name]
    @token_digest = attrs[:token_digest]
    @created_at   = attrs[:created_at]
    @last_used_at = attrs[:last_used_at]
    @expires_at   = attrs[:expires_at]
  end

  # Timestamps for display. The store is a plain JSON file a user may have
  # written by hand. A malformed value must not take down the whole token
  # page, and the raw string is more useful to whoever has to fix it than a
  # blank cell would be.
  def created_at_display(fallback = '-')
    format_timestamp(created_at, fallback)
  end

  def last_used_at_display(fallback)
    format_timestamp(last_used_at, fallback)
  end

  # @param never [String] what to show for a token that does not expire
  def expires_at_display(never)
    format_timestamp(expires_at, never)
  end

  # True once the expiry has passed, and for a value that is not a time.
  def expired?
    OodApi::TokenPolicy.expired?(expires_at)
  end

  def destroy
    OodApi::ApiToken.destroy(id)
  end

  private

  def format_timestamp(value, fallback)
    return fallback if value.nil? || value.to_s.strip.empty?

    Time.parse(value.to_s).strftime('%Y-%m-%d %H:%M')
  rescue ArgumentError, TypeError
    value.to_s
  end
end
