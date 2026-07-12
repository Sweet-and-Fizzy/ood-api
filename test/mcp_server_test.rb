# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/mcp_server'

# Exercises the MCP server assembly and the /mcp rack app. These are the
# pieces mounted in config.ru, and they were previously untested
# (0% coverage on app/mcp_server.rb).
class McpServerTest < Minitest::Test
  include TestHelpers

  def test_build_mcp_server_registers_all_tools
    server = OodApi.build_mcp_server

    # server.tools is a Hash of tool_name => ToolClass.
    names = server.tools.keys.join(',')
    assert(server.tools.length >= 19, "expected all tools mounted, got #{server.tools.length}")
    assert_includes names, 'cluster'
    assert_includes names, 'job'
    assert_includes names, 'file'
    assert_includes names, 'env'
  end

  def test_build_mcp_server_registers_context_resource
    server = OodApi.build_mcp_server
    uris = server.resources.map(&:uri)
    assert_includes uris, 'ood://context'
  end

  def test_mcp_rack_app_is_callable
    assert_respond_to OodApi.mcp_rack_app, :call
  end

  def test_mcp_rack_app_handles_initialize_request
    app = OodApi.mcp_rack_app
    body = JSON.generate(
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } }
    )
    env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, _headers, _resp = app.call(env)
    assert_kind_of Integer, status
    assert_operator status, :<, 500, "MCP transport returned server error: #{status}"
  end

  def test_context_resource_read_returns_site_context
    Handlers::Context.stubs(:read).returns('# Site policies')
    server = OodApi.build_mcp_server

    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'resources/read',
                            params: { uri: 'ood://context' })
    result = JSON.parse(server.handle_json(request))

    contents = result.dig('result', 'contents')
    assert_equal 'ood://context', contents.first['uri']
    assert_includes contents.first['text'], 'Site policies'
  end

  def test_context_resource_read_unknown_uri_returns_empty
    server = OodApi.build_mcp_server

    request = JSON.generate(jsonrpc: '2.0', id: 2, method: 'resources/read',
                            params: { uri: 'ood://nonexistent' })
    result = JSON.parse(server.handle_json(request))

    assert_empty result.dig('result', 'contents')
  end

  def test_tools_list_is_served
    server = OodApi.build_mcp_server
    request = JSON.generate(jsonrpc: '2.0', id: 3, method: 'tools/list', params: {})
    result = JSON.parse(server.handle_json(request))

    tool_names = result.dig('result', 'tools').map { |t| t['name'] }
    assert_includes tool_names, 'submit_job'
    assert_includes tool_names, 'list_clusters'
  end
end
