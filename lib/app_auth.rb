# frozen_string_literal: true

require_relative 'api_token'

module OodApi
  # Application-level token authentication, shared by the REST app and the MCP
  # transport so both surfaces enforce the same rule.
  #
  # Default: no app-level check. OOD has already authenticated the user
  # upstream (Apache + mod_ood_proxy) and the PUN runs as that user, so any
  # Authorization header was for Apache's eyes and is opaque to us.
  #
  # Opt-in: OOD_API_APP_TOKENS=true requires a token issued by the Dashboard
  # plugin on every request, as a second factor on top of Apache.
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

    def enabled?
      ENV['OOD_API_APP_TOKENS'] == 'true'
    end

    # Returns the presented token, or nil.
    def extract_token(env)
      value = env[TOKEN_HEADER]
      value.nil? || value.empty? ? nil : value
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

      ApiToken.touch(token)
      token
    end
  end
end
