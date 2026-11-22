# frozen_string_literal: true

require_relative 'lib/site_config'

# The app's env file, in its directory under /etc/ood/config/apps. Loaded
# before the app so every setting read at load time sees it.
OodApi::SiteConfig.load_app_env!

require_relative 'app/api'
require_relative 'app/mcp_server'

# Once per PUN start, so an admin can see what their settings produced.
OodApi::Capabilities.announce

file_access = Handlers::Files.access_mode
OodApi::Log.line "op=file_access status=#{file_access == :unavailable ? 'error' : 'ok'} mode=#{file_access}"

app = Rack::Builder.new do
  map('/mcp') { run OodApi.mcp_rack_app }
  map('/') { run OodApi::App }
end

run app
