# frozen_string_literal: true

require 'time'
require_relative 'site_config'

module OodApi
  # How long application tokens live. Every token has an expiry unless the
  # site allows tokens that never expire. Settings come from the environment
  # (`OOD_API_TOKEN_MAX_DAYS`, `OOD_API_TOKEN_ALLOW_NEVER`) or from the app's
  # config.yml in /etc/ood/config/apps/<app>:
  #
  #   token_max_days: 180
  #   token_allow_never: true
  #
  # The Dashboard token page calls this module to decide what to offer.
  module TokenPolicy
    DEFAULT_MAX_DAYS = 365
    DAY = 86_400

    module_function

    # @return [Integer] the longest lifetime a token may be given, in days
    def max_days
      days = Integer((setting('OOD_API_TOKEN_MAX_DAYS', :token_max_days) || DEFAULT_MAX_DAYS).to_s.strip, 10)
      days.positive? ? days : DEFAULT_MAX_DAYS
    rescue ArgumentError, TypeError
      DEFAULT_MAX_DAYS
    end

    # @return [Array<String>] what is wrong with the lifetime the site set
    def problems
      raw = setting('OOD_API_TOKEN_MAX_DAYS', :token_max_days)
      return [] if raw.nil? || Integer(raw.to_s.strip, 10).positive?

      ["token_max_days must be a number of days, not #{raw.inspect}"]
    rescue ArgumentError
      ["token_max_days must be a number of days, not #{raw.inspect}"]
    end

    # @return [Boolean] whether a token may have no expiry at all
    def allow_never?
      ['true', '1', 'yes', 'on'].include?(setting('OOD_API_TOKEN_ALLOW_NEVER', :token_allow_never).to_s.strip.downcase)
    end

    # The expiry given to a token that has none recorded: the site maximum,
    # counted from now. Tokens created before expiry existed get this the
    # first time the store is rewritten.
    #
    # @return [String] an ISO 8601 time
    def default_expiry(now = Time.now)
      (now + (max_days * DAY)).iso8601
    end

    # Whether a stored entry's expiry has to be rewritten: it has none
    # recorded, it says "never" at a site that does not allow that, or it is
    # further away than the site maximum allows.
    #
    # The token store is a file its owner can edit, so the maximum is applied
    # here as well as by the page that creates tokens. A date beyond it is
    # pulled back to the maximum, counted from now, which also shortens
    # existing tokens when a site lowers the maximum.
    def needs_expiry?(attrs, now = Time.now)
      return true unless attrs.key?(:expires_at)
      return !allow_never? if attrs[:expires_at].nil?
      # Anything else must be a time. `false` or a number in a hand-edited
      # file would otherwise read as "never" and never be corrected.
      return true unless attrs[:expires_at].is_a?(String)

      beyond_maximum?(attrs[:expires_at], now)
    end

    def beyond_maximum?(expires_at, now = Time.now)
      Time.iso8601(expires_at.to_s) > now + (max_days * DAY)
    rescue ArgumentError
      false
    end

    # @param expires_at [String, nil] the stored expiry; nil means never
    # @return [Boolean] true once the expiry has passed, and for a value that
    #   is not a time at all
    def expired?(expires_at, now = Time.now)
      return false if expires_at.nil?

      Time.iso8601(expires_at.to_s) <= now
    rescue ArgumentError
      true
    end

    def setting(env_name, key)
      SiteConfig.setting(env_name, key)
    end
  end
end
