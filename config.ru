# frozen_string_literal: true

require_relative 'app/api'
require_relative 'app/mcp_server'

# In production under Passenger, Passenger handles streaming Proc
# bodies natively — no special middleware needed. For local development
# with MCP SSE streaming, use bin/dev instead of rackup.

app = Rack::Builder.new do
  map('/mcp') { run OodApi.mcp_rack_app }
  map('/') { run OodApi::App }
end

run app
