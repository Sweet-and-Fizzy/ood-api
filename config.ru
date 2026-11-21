# frozen_string_literal: true

require_relative 'app/api'
require_relative 'app/mcp_server'

# One line per PUN start, so an admin can see what their settings produced.
OodApi::Capabilities.problems.each do |problem|
  warn "ood_api_audit op=capabilities status=error error=\"#{problem}; falling back to read-only\""
end
warn "ood_api_audit op=capabilities status=ok #{OodApi::Capabilities.summary}"

app = Rack::Builder.new do
  map('/mcp') { run OodApi.mcp_rack_app }
  map('/') { run OodApi::App }
end

run app
