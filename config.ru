# frozen_string_literal: true

require_relative 'lib/site_config'

# This app's own settings, in the place Open OnDemand keeps per-app settings.
# Loaded before the app so every setting read at load time sees them.
app_name = File.basename(ENV['PASSENGER_BASE_URI'] || __dir__)
OodApi::SiteConfig.load_app_env!(ENV['OOD_API_ENV_FILE'] || "/etc/ood/config/apps/#{app_name}/env")

require_relative 'app/api'
require_relative 'app/mcp_server'

# Once per PUN start, so an admin can see what their settings produced.
OodApi::Capabilities.announce
warn "ood_api_audit op=app_tokens status=ok required=#{OodApi::AppAuth.enabled?}"

file_access = Handlers::Files.access_mode
warn "ood_api_audit op=file_access status=#{file_access == :unavailable ? 'error' : 'ok'} mode=#{file_access}"

app = Rack::Builder.new do
  map('/mcp') { run OodApi.mcp_rack_app }
  map('/') { run OodApi::App }
end

run app
