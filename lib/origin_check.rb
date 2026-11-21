# frozen_string_literal: true

require 'uri'

module OodApi
  # Refuses browser requests that come from another site.
  #
  # The user's OOD session cookie rides along on any request their browser
  # makes to the portal, including one a page on another site triggers. The
  # JSON-only rule already stops HTML forms, and a scripted cross-origin
  # request fails its CORS preflight because this app sends no CORS headers.
  # That second half is a property of the deployment, not of this app: one
  # broad `Access-Control-Allow-*` header added at Apache removes it. This
  # check does not depend on that.
  #
  # Non-browser clients send neither header and are unaffected.
  module OriginCheck
    SAME_SITE_VALUES = ['same-origin', 'none'].freeze

    module_function

    # Extra origins a site allows, e.g. a separately hosted front end:
    # OOD_API_ALLOWED_ORIGINS="https://portal.example.edu,https://x.example.edu"
    def allowed_origins
      ENV['OOD_API_ALLOWED_ORIGINS'].to_s.split(',').map { |o| o.strip.downcase.chomp('/') }.reject(&:empty?)
    end

    def cross_site?(env)
      origin = env['HTTP_ORIGIN'].to_s.strip.downcase
      unless origin.empty?
        return false if allowed_origins.include?(origin.chomp('/'))

        # An Origin header is the authoritative signal when present.
        return !same_host?(origin, env)
      end

      fetch_site = env['HTTP_SEC_FETCH_SITE'].to_s.strip.downcase
      !fetch_site.empty? && !SAME_SITE_VALUES.include?(fetch_site)
    end

    # Apache may sit behind another proxy that rewrites Host, so the forwarded
    # host counts too. A cross-site page cannot set either header.
    def same_host?(origin, env)
      authority = authority_of(origin)
      return false unless authority

      [env['HTTP_HOST'], env['HTTP_X_FORWARDED_HOST']].any? do |host|
        host.to_s.split(',').any? { |h| strip_default_port(h.strip.downcase) == authority }
      end
    end

    def authority_of(origin)
      uri = URI.parse(origin)
      return nil unless uri.host && ['http', 'https'].include?(uri.scheme)

      uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
    rescue URI::InvalidURIError
      nil
    end

    def strip_default_port(host)
      host.sub(/:(80|443)\z/, '')
    end
  end
end
