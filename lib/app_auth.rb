# frozen_string_literal: true

require_relative 'api_token'
require_relative 'capabilities'

module OodApi
  # Application-level token authentication, shared by the REST app and the MCP
  # transport so both surfaces enforce the same rule.
  #
  # Default: no app-level check. OOD has already authenticated the user
  # upstream (Apache + mod_ood_proxy) and the PUN runs as that user, so any
  # Authorization header was for Apache's eyes and is opaque to us.
  #
  # Opt-in: OOD_API_APP_TOKENS=true requires a token issued by the Dashboard
  # plugin on every request, on top of Apache. This gives each client a
  # credential that can be revoked on its own; it is not an independent second
  # factor, since anyone signed in as the user can issue one.
  module AppAuth
    # App tokens are presented in their own header, never in Authorization.
    #
    # Apache owns `Authorization`: when configured for bearer validation
    # (AuthType auth-openidc) it consumes that header for the IdP's JWT,
    # leaving nowhere for a second credential. A dedicated header lets a
    # client satisfy both — Authorization for Apache, X-OOD-API-Token for us —
    # and is what allows the MCP surface to use app tokens at all.
    TOKEN_HEADER = 'HTTP_X_OOD_API_TOKEN'

    module_function

    # `OOD_API_APP_TOKENS=true`, or `app_tokens: true` in the app's
    # config.yml. A value that is neither true nor false is reported by
    # OodApi::Capabilities, which serves nothing until it is fixed.
    def enabled?
      Capabilities::ON.include?(SiteConfig.setting('OOD_API_APP_TOKENS', :app_tokens).to_s.strip.downcase)
    end

    # Returns the presented token, or nil.
    def extract_token(env)
      value = env[TOKEN_HEADER]
      value.nil? || value.empty? ? nil : value
    end

    # An expired token is refused like an unknown one, but the log says which
    # token it was, so its owner can tell why a client stopped working.
    def log_expired(token)
      OodApi::Log.line "op=authenticate status=expired token_id=#{token.id}"
    end

    # Returns the ApiToken when authentication passes (or when app tokens are
    # disabled, in which case nil is a pass, not a failure). Returns false when
    # a token is required and the presented one is missing or invalid.
    def authenticate(env)
      return nil unless enabled?

      value = extract_token(env)
      return false unless value

      token = ApiToken.find_by_token(value)
      return false unless token

      if token.expired?
        log_expired(token)
        return false
      end

      ApiToken.touch(token)
      token
    end
  end
end
