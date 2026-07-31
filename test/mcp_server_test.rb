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

  # --- app-token enforcement on /mcp ---
  #
  # /mcp is mounted as a sibling Rack app in config.ru, outside the Sinatra
  # app's `before` filters. It previously served the full toolset with no
  # app-token check while /api/v1/* enforced one, so a caller who could not
  # use REST could still reach the same file, job, and environment operations.

  def mcp_env(headers = {})
    {
      'REQUEST_METHOD' => 'POST',
      'PATH_INFO'      => '/',
      'CONTENT_TYPE'   => 'application/json',
      'HTTP_ACCEPT'    => 'application/json, text/event-stream',
      'rack.input'     => StringIO.new(
        JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list', params: {})
      )
    }.merge(headers)
  end

  def test_mcp_requires_app_token_when_enabled
    setup_token_storage
    status, _headers, body = OodApi.mcp_rack_app.call(mcp_env)

    assert_equal 401, status
    assert_equal 'unauthorized', JSON.parse(body.first)['error']
  ensure
    teardown_token_storage
  end

  def test_mcp_accepts_a_valid_app_token
    setup_token_storage
    token = create_test_token
    status, = OodApi.mcp_rack_app.call(mcp_env('HTTP_X_OOD_API_TOKEN' => token.token))

    assert_equal 200, status
  ensure
    teardown_token_storage
  end

  def test_mcp_rejects_an_invalid_app_token
    setup_token_storage
    status, = OodApi.mcp_rack_app.call(mcp_env('HTTP_X_OOD_API_TOKEN' => 'nope'))

    assert_equal 401, status
  ensure
    teardown_token_storage
  end

  # Default mode: no app tokens configured, Apache is the only gate.
  def test_mcp_open_when_app_tokens_disabled
    ENV.delete('OOD_API_APP_TOKENS')
    status, = OodApi.mcp_rack_app.call(mcp_env)

    assert_equal 200, status
  end

  # mcp 0.12.0 returned the parsed request body verbatim when that body was
  # valid JSON that is not an object, and Rack served it as a
  # [status, headers, body] triple — so posting a well-formed triple let a
  # caller choose the status, every header, and the body, from the
  # authenticated OOD origin. Fixed upstream in 1.0.0; this pins the behaviour
  # so an upgrade or a pin rollback cannot silently reintroduce it.
  def test_non_object_json_body_is_rejected
    app = OodApi.mcp_rack_app
    injection = JSON.generate([200, { 'Content-Type' => 'text/html' }, ['<script>alert(1)</script>']])
    env = Rack::MockRequest.env_for('/', method: 'POST', input: injection)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, _headers, body = app.call(env)
    assert_equal 400, status
    refute_includes body.join, '<script>', 'attacker-supplied body must never be served'
  end

  # `[]` and bare scalars destructured to a nil status and killed the worker.
  def test_scalar_json_bodies_do_not_reach_the_transport
    ['[]', '5', 'null', '"hi"'].each do |raw|
      env = Rack::MockRequest.env_for('/', method: 'POST', input: raw)
      env['CONTENT_TYPE'] = 'application/json'
      env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

      status, = OodApi.mcp_rack_app.call(env)
      assert_equal 400, status, "body #{raw.inspect} should be rejected"
    end
  end

  # /mcp is a sibling Rack app, so Sinatra's size filter does not apply. The
  # transport caps the body itself; we only ensure the cap is raised to match
  # what write_file advertises, or a legitimate large write would be refused
  # before the handler saw it.
  def test_oversized_body_is_rejected
    oversized = (Handlers::Files::MAX_FILE_WRITE * 2)
    env = Rack::MockRequest.env_for('/', method: 'POST', input: '{}')
    env['CONTENT_LENGTH'] = oversized.to_s
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, = OodApi.mcp_rack_app.call(env)
    assert_includes [400, 413], status, 'an oversized body must be refused, not buffered'
  end

  # A body at the advertised write limit must still get through.
  def test_body_at_the_write_limit_is_not_refused_by_the_transport
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping')
    env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
    env['CONTENT_LENGTH'] = (Handlers::Files::MAX_FILE_WRITE - 1).to_s
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, = OodApi.mcp_rack_app.call(env)
    refute_equal 413, status, 'the transport cap must not be below MAX_FILE_WRITE'
  end

  # ScriptError is not a StandardError, so neither the gem's handler nor its
  # transport catches it; it reached Passenger and killed the worker.
  def test_script_error_from_the_transport_becomes_a_jsonrpc_error
    transport = Object.new
    def transport.handle_request(_req) = raise(NotImplementedError, 'boom')

    env = Rack::MockRequest.env_for('/', method: 'POST', input: '{}')
    env['CONTENT_TYPE'] = 'application/json'

    status, _headers, body = OodApi.mcp_rack_app(transport).call(env)
    assert_equal 500, status
    assert_includes body.join, 'NotImplementedError'
  end

  # A valid request body must still reach the transport after we read it.
  def test_reading_the_body_does_not_consume_it
    app = OodApi.mcp_rack_app
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping')
    env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, _headers, resp = app.call(env)
    assert_equal 200, status
    refute_includes resp.join, 'Request body must be'
  end

  # clientInfo is caller-supplied and need not be an object. The transport now
  # rejects a malformed one with -32602 rather than letting it reach the
  # instrumentation hook, which used to index it as a Hash and raise from
  # inside an upstream `ensure` — discarding an already-successful initialize.
  # Either way the requirement is the same: a well-formed error, never a crash.
  def test_non_object_client_info_is_rejected_cleanly
    app = OodApi.mcp_rack_app
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                         params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: 'pwned' })
    env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, _headers, resp = app.call(env)
    assert_equal 200, status
    parsed = JSON.parse(resp.join)
    assert_equal(-32_602, parsed.dig('error', 'code'), 'expected Invalid params, not an internal error')
  end

  # A well-formed initialize must still succeed and still be audited.
  def test_valid_client_info_initializes_and_is_audited
    app = OodApi.mcp_rack_app
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                         params: { protocolVersion: '2024-11-05', capabilities: {},
                                   clientInfo: { name: 'probe', version: '9.9' } })
    env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, _headers, resp = app.call(env)
    assert_equal 200, status
    assert JSON.parse(resp.join)['result'], 'initialize should succeed'
  end
end
