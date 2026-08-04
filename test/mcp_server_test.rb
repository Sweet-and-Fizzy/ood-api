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

  # mcp 1.0.0 added DNS-rebinding protection defaulting to an allowlist of
  # loopback only, so every request whose Host is a real hostname 403s. That
  # is every OOD site. It shipped broken in v0.2.0 because every check — unit
  # and live — used localhost, which is inside the gem's default allowlist.
  #
  # Assert a hostname that is NOT loopback. A test using localhost passes
  # whether or not the protection is enabled, which is how this was missed.
  def test_mcp_accepts_a_real_site_hostname
    app = OodApi.mcp_rack_app
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'ping')

    ['ondemand.example.edu', 'ood.university.edu:443'].each do |host|
      env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
      env['CONTENT_TYPE'] = 'application/json'
      env['HTTP_ACCEPT'] = 'application/json, text/event-stream'
      env['HTTP_HOST'] = host

      status, = app.call(env)
      assert_equal 200, status, "Host: #{host} must be served — Apache validates Host upstream"
    end
  end

  # JSON has no Infinity literal, but `1e400` overflows to Float::INFINITY on
  # parse. json_schemer validates an integer-typed param by calling
  # Float#floor, which raises FloatDomainError — so the schema check died
  # before any handler ran and the app's own numeric guards never executed.
  # The client saw -32603 internal error for what is a client mistake.
  def test_non_finite_numbers_are_rejected_as_invalid_params
    app = OodApi.mcp_rack_app

    bodies = {
      'max_size'  => '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
                     '{"name":"read_file","arguments":{"path":"/tmp/x","max_size":1e400}}}',
      'negative'  => '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
                     '{"name":"read_file","arguments":{"path":"/tmp/x","max_size":-1e400}}}',
      'wall_time' => '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
                     '{"name":"submit_job","arguments":{"cluster_id":"c","script_content":"x","wall_time":1e400}}}'
    }

    bodies.each do |label, body|
      env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
      env['CONTENT_TYPE'] = 'application/json'
      env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

      status, _headers, resp = app.call(env)
      parsed = JSON.parse(Array(resp).join)

      assert_equal 400, status, "#{label}: a non-finite number is a client error"
      assert_equal(-32_602, parsed.dig('error', 'code'),
                   "#{label}: must be invalid params, not internal error")
    end
  end

  # The guard reads the body to inspect it; the transport must still see it.
  def test_ordinary_tool_calls_still_reach_the_transport
    app = OodApi.mcp_rack_app
    body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

    status, _headers, resp = app.call(env)
    parsed = JSON.parse(Array(resp).join)

    assert_equal 200, status
    assert parsed.dig('result', 'tools')&.any?, 'tools/list must still be served'
  end

  # A tools/call whose `arguments` is a non-object reaches the mcp gem's schema
  # check, which calls `.keys` on it and raises for any tool with a required
  # parameter — surfacing a client mistake as a -32603 internal error. It is
  # refused as invalid params before the transport sees it.
  def test_non_object_tool_arguments_are_rejected_as_invalid_params
    app = OodApi.mcp_rack_app
    ['[1,2]', '5', '"hi"', 'true'].each do |args|
      body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
             "{\"name\":\"get_cluster\",\"arguments\":#{args}}}"
      env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
      env['CONTENT_TYPE'] = 'application/json'
      env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

      status, _headers, resp = app.call(env)
      parsed = JSON.parse(Array(resp).join)

      assert_equal 400, status, "arguments=#{args} must be a 400"
      assert_equal(-32_602, parsed.dig('error', 'code'),
                   "arguments=#{args} must be invalid params, not internal error")
    end
  end

  # A well-formed object, and an absent or null arguments (the gem coerces the
  # latter to an empty hash), must still pass through to the transport.
  def test_object_and_absent_tool_arguments_still_reach_the_transport
    app = OodApi.mcp_rack_app
    ['"arguments":{"cluster_id":"c1"}', '"arguments":null'].each do |args|
      body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
             "{\"name\":\"get_cluster\",#{args}}}"
      env = Rack::MockRequest.env_for('/', method: 'POST', input: body)
      env['CONTENT_TYPE'] = 'application/json'
      env['HTTP_ACCEPT'] = 'application/json, text/event-stream'

      status, _headers, resp = app.call(env)
      parsed = JSON.parse(Array(resp).join)

      assert_equal 200, status, "#{args} must reach the transport"
      # a clean tool-level response, not the -32602 pre-check rejection
      refute_equal(-32_602, parsed.dig('error', 'code'),
                   "#{args} must not be refused by the shape pre-check")
    end
  end

  # Post a raw JSON-RPC body and return [status, error_code].
  def mcp_post(raw)
    env = Rack::MockRequest.env_for('/', method: 'POST', input: raw)
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'
    status, _headers, resp = OodApi.mcp_rack_app.call(env)
    [status, JSON.parse(Array(resp).join).dig('error', 'code')]
  end

  # JSON-RPC permits `params` to be an array, and the gem's own param check
  # accepts a missing one — but the gem's method handlers index params as an
  # object (`request[:name]`, `request.dig(:_meta, …)`). A non-object or, for
  # tools/call, an absent params reached those handlers and raised, surfacing
  # as a -32603 (and, for the guard's own dig into a non-hash params, a 500).
  # All are refused as invalid params before the transport.
  def test_non_object_params_are_rejected_as_invalid_params
    [
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1,2]}',
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":5}',
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":null}',
      '{"jsonrpc":"2.0","id":1,"method":"tools/call"}',
      '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":[]}',
      # resources/read reads params[:uri]; a null or absent params reaches
      # nil[:uri] in the app's own handler, the same shape tools/call has.
      '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":null}',
      '{"jsonrpc":"2.0","id":1,"method":"resources/read"}',
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":"x"}'
    ].each do |raw|
      status, code = mcp_post(raw)
      assert_equal 400, status, "#{raw} must be a 400, not a 500 or 200"
      assert_equal(-32_602, code, "#{raw} must be invalid params, not internal error")
    end
  end

  # resources/read and ping/tools/list differ on absent params: the first needs
  # a uri, the others take none. An empty-object params for resources/read is
  # valid (the handler returns empty contents) and must reach the transport.
  def test_resources_read_with_object_params_reaches_the_transport
    ['{}', '{"uri":"ood://context"}'].each do |params|
      raw = %({"jsonrpc":"2.0","id":1,"method":"resources/read","params":#{params}})
      status, code = mcp_post(raw)
      assert_equal 200, status, "params=#{params} must reach the transport"
      assert_nil code, "params=#{params} must not be refused by a pre-check"
    end
  end

  # `call_tool` also digs `params._meta.progressToken` unconditionally, so a
  # tools/call with a valid params object but a non-object `_meta` passes the
  # top-level params check and still crashes the gem — a valid params does not
  # imply a valid `_meta`. Refused as invalid params, like `arguments`.
  def test_non_object_tool_meta_is_rejected_as_invalid_params
    base = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
           '{"name":"list_clusters","arguments":{},"_meta":%s}}'
    ['"notahash"', '[1,2]', '5', 'true'].each do |meta|
      status, code = mcp_post(format(base, meta))
      assert_equal 400, status, "_meta=#{meta} must be a 400"
      assert_equal(-32_602, code, "_meta=#{meta} must be invalid params, not internal error")
    end
  end

  # A valid object `_meta`, and its absence, must not be refused by a pre-check
  # — the request should reach the transport. (It then runs the real tool; with
  # no cluster config in the test env that returns a tool-level error, which is
  # past the pre-check and not what this asserts.)
  def test_valid_or_absent_tool_meta_reaches_the_transport
    ['"_meta":{"progressToken":"t1"},', ''].each do |meta|
      raw = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":' \
            "{\"name\":\"list_clusters\",#{meta}\"arguments\":{}}}"
      _status, code = mcp_post(raw)
      refute_equal(-32_602, code, "#{meta.inspect} must not be refused as invalid params")
      refute_equal(-32_601, code, "#{meta.inspect} must not be refused as method not found")
    end
  end

  # Methods the app does not implement (no prompts, completion, subscriptions,
  # or log-level handler) were dispatched by the gem and failed as -32603
  # internal errors. They are refused as -32601 method-not-found, the honest
  # code, before the transport.
  def test_unsupported_methods_are_method_not_found
    [
      '{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"x"}}',
      '{"jsonrpc":"2.0","id":1,"method":"completion/complete","params":{"ref":{}}}',
      '{"jsonrpc":"2.0","id":1,"method":"resources/subscribe","params":{"uri":"x"}}',
      '{"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{"level":"debug"}}'
    ].each do |raw|
      status, code = mcp_post(raw)
      assert_equal(-32_601, code, "#{raw} must be method-not-found, not internal error")
      assert_equal 400, status
    end
  end

  # A method the app DOES support with a well-formed object params must still
  # reach the transport, not be caught by any pre-check.
  def test_supported_methods_with_object_params_reach_the_transport
    [
      '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}',
      '{"jsonrpc":"2.0","id":1,"method":"ping"}',
      '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"ood://context"}}'
    ].each do |raw|
      status, code = mcp_post(raw)
      assert_equal 200, status, "#{raw} must reach the transport"
      assert_nil code, "#{raw} must not be refused by a pre-check"
    end
  end
end
