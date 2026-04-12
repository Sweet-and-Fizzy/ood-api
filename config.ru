# frozen_string_literal: true

require_relative 'app/api'
require_relative 'app/mcp_server'

app = Rack::Builder.new do
  map('/mcp') { run OodApi.mcp_rack_app }
  map('/') { run OodApi::App }
end

run app
