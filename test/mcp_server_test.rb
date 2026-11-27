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

  # Clients use these hints to decide what needs a human confirmation step.
  # The SDK defaults an unannotated tool to destructive and open-world, so
  # every tool must state its hints explicitly. Values are
  # [readOnlyHint, destructiveHint, idempotentHint].
  EXPECTED_ANNOTATIONS = {
    'list_clusters'             => [true,  false, true],
    'get_cluster'               => [true,  false, true],
    'list_accounts'             => [true,  false, true],
    'list_queues'               => [true,  false, true],
    'get_cluster_info'          => [true,  false, true],
    'list_jobs'                 => [true,  false, true],
    'get_job'                   => [true,  false, true],
    'list_historic_jobs'        => [true,  false, true],
    'list_files'                => [true,  false, true],
    'find_files'                => [true,  false, true],
    'list_interactive_sessions' => [true, false, true],
    'list_interactive_apps'     => [true, false, true],
    'list_software'             => [true, false, true],
    'get_quota_and_balance'     => [true, false, true],
    'list_projects'             => [true, false, true],
    'get_project'               => [true, false, true],
    'open_launcher'             => [true, false, true],
    'read_file'                 => [true,  false, true],
    'list_env'                  => [true,  false, true],
    'get_env'                   => [true,  false, true],
    'submit_job'                => [false, true, false],
    'hold_job'                  => [false, false, true],
    'release_job'               => [false, false, true],
    'create_directory'          => [false, false, true],
    'write_file'                => [false, true, false],
    'cancel_job'                => [false, true,  true],
    'delete_file'               => [false, true,  true]
  }.freeze

  def test_every_tool_declares_annotations
    server = OodApi.build_mcp_server
    request = JSON.generate(jsonrpc: '2.0', id: 4, method: 'tools/list', params: {})
    tools = JSON.parse(server.handle_json(request)).dig('result', 'tools')

    assert_equal EXPECTED_ANNOTATIONS.keys.sort, tools.map { |t| t['name'] }.sort,
                 'a new tool needs an entry in EXPECTED_ANNOTATIONS'

    tools.each do |tool|
      read_only, destructive, idempotent = EXPECTED_ANNOTATIONS.fetch(tool['name'])
      hints = tool['annotations']
      refute_nil hints, "#{tool['name']} has no annotations"
      assert_equal read_only, hints['readOnlyHint'], "#{tool['name']} readOnlyHint"
      assert_equal destructive, hints['destructiveHint'], "#{tool['name']} destructiveHint"
      assert_equal idempotent, hints['idempotentHint'], "#{tool['name']} idempotentHint"
      # A job runs on a compute node with network access; nothing else here
      # reaches beyond the cluster's own filesystem and scheduler.
      assert_equal tool['name'] == 'submit_job', hints['openWorldHint'], "#{tool['name']} openWorldHint"
    end
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

  def test_mcp_refuses_cross_site_requests
    status, = OodApi.mcp_rack_app.call(mcp_env('HTTP_HOST'   => 'ood.example.edu',
                                               'HTTP_ORIGIN' => 'https://evil.example'))
    assert_equal 403, status

    status, = OodApi.mcp_rack_app.call(mcp_env('HTTP_HOST'   => 'ood.example.edu',
                                               'HTTP_ORIGIN' => 'https://ood.example.edu'))
    assert_equal 200, status
  end

  def test_mcp_body_is_bounded_before_it_is_parsed
    big = StringIO.new('a' * (OodApi.max_request_bytes + 10))
    JSON.expects(:parse).never

    status, = OodApi.mcp_rack_app.call(mcp_env('rack.input' => big))

    assert_equal 413, status
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

  # The 2026-07-28 protocol has no `initialize`: a client names itself in each
  # request's `_meta`. The client record must still be written, once.
  MODERN_VERSION = '2026-07-28'

  def modern_body(id, client_info, method: 'tools/list')
    meta = { 'io.modelcontextprotocol/protocolVersion'    => MODERN_VERSION,
             'io.modelcontextprotocol/clientCapabilities' => {} }
    meta['io.modelcontextprotocol/clientInfo'] = client_info unless client_info.nil?
    message = { jsonrpc: '2.0', method: method, params: { _meta: meta } }
    message[:id] = id unless id.nil?
    JSON.generate(message)
  end

  # @return [Array(Integer, Hash, String)] status, parsed reply, audit output
  def post_capturing_audit(body, headers = {})
    OodApi.forget_mcp_clients! unless @keep_seen_clients
    env = Rack::MockRequest.env_for('/', { method: 'POST', input: body }.merge(headers))
    env['CONTENT_TYPE'] = 'application/json'
    env['HTTP_ACCEPT'] = 'application/json, text/event-stream'
    if body.include?(MODERN_VERSION)
      env['HTTP_MCP_PROTOCOL_VERSION'] = MODERN_VERSION
      env['HTTP_MCP_METHOD'] = JSON.parse(body)['method']
    end
    status = reply = nil
    _out, err = capture_io do
      status, _headers, resp = OodApi.mcp_rack_app.call(env)
      text = Array(resp).join
      reply = text.empty? ? {} : JSON.parse(text)
    end
    [status, reply, err]
  end

  def client_lines(err)
    err.lines.grep(/op=mcp_initialize/)
  end

  def test_modern_client_info_is_audited
    status, reply, err = post_capturing_audit(modern_body(1, { name: 'ood-agent', version: '2.0.1' }))
    assert_equal 200, status
    assert reply['result'], "tools/list should succeed: #{reply}"
    lines = client_lines(err)
    assert_equal 1, lines.length, err
    assert_match(/op=mcp_initialize user=\S+ source=mcp client=ood-agent client_version=2\.0\.1 \
protocol_version=#{MODERN_VERSION}/o, lines.first)
    refute_match(/duration=/, lines.first)
  end

  def test_modern_client_is_audited_once
    OodApi.forget_mcp_clients!
    @keep_seen_clients = true
    _, _, first = post_capturing_audit(modern_body(1, { name: 'ood-agent', version: '2.0.1' }))
    _, reply, second = post_capturing_audit(modern_body(2, { name: 'ood-agent', version: '2.0.1' }))
    assert reply['result']
    assert_equal 1, client_lines(first).length
    assert_empty client_lines(second), 'a second request from the same client must not be recorded again'
  end

  # The HTTP endpoint is one long-lived process for every client of the PUN,
  # so a second, different client is still recorded.
  def test_a_different_modern_client_is_audited_too
    OodApi.forget_mcp_clients!
    @keep_seen_clients = true
    post_capturing_audit(modern_body(1, { name: 'ood-agent', version: '2.0.1' }))
    _, _, err = post_capturing_audit(modern_body(2, { name: 'other-client', version: '1.0' }))
    assert_match(/client=other-client/, client_lines(err).join)
  end

  def test_legacy_initialize_line_is_unchanged
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                         params: { protocolVersion: '2025-06-18', capabilities: {},
                                   clientInfo: { name: 'probe', version: '9.9' } })
    _, reply, err = post_capturing_audit(body)
    assert reply['result']
    lines = client_lines(err)
    assert_equal 1, lines.length, err
    assert_match(/ op=mcp_initialize user=\S+ source=mcp client=probe client_version=9\.9$/, lines.first.chomp)
  end

  def test_modern_request_without_client_info_is_served_and_not_audited
    _, reply, err = post_capturing_audit(modern_body(1, nil))
    assert reply['result']
    assert_empty client_lines(err)
  end

  # Self-reported and caller-controlled: a malformed identity never fails the
  # request and is never written.
  def test_malformed_modern_client_info_never_breaks_the_request
    [{ name: 42, version: '1' }, { name: 'x', version: ['1'] }, { version: '1' }, { name: '' },
     { name: { a: 1 }, version: '1' }].each do |info|
      status, reply, err = post_capturing_audit(modern_body(1, info))
      assert_equal 200, status
      assert reply['result'], "clientInfo=#{info} should still be served: #{reply}"
      assert_empty client_lines(err), "clientInfo=#{info} must not be recorded"
      refute_match(/mcp_instrumentation_failed/, err)
    end
  end

  # A non-object clientInfo or _meta is refused by the gem as invalid params,
  # cleanly, and nothing is recorded.
  def test_non_object_modern_client_info_or_meta_is_refused_cleanly
    meta_scalar = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list', params: { _meta: 'pwned' })
    [modern_body(1, 'pwned'), modern_body(1, [1, 2]), meta_scalar].each do |body|
      status, reply, err = post_capturing_audit(body)
      assert_operator status, :<, 500, body
      assert_equal(-32_602, reply.dig('error', 'code'), "#{body} should be invalid params: #{reply}")
      assert_empty client_lines(err)
      refute_match(/mcp_instrumentation_failed/, err)
    end
  end

  def test_huge_modern_client_name_is_truncated
    _, reply, err = post_capturing_audit(modern_body(1, { name: 'a' * 100_000, version: 'v' * 100_000 }))
    assert reply['result']
    line = client_lines(err).first
    refute_nil line
    assert_operator line.bytesize, :<, 2_000
  end

  # The HTTP endpoint serves every app token from one process, so the same
  # client connecting under a second token is a second record.
  def test_same_modern_client_under_another_token_is_audited_again
    setup_token_storage
    OodApi.forget_mcp_clients!
    @keep_seen_clients = true
    body = modern_body(1, { name: 'ood-agent', version: '2.0.1' })
    first = create_test_token('A')
    second = create_test_token('B')
    _, _, err_a = post_capturing_audit(body, 'HTTP_X_OOD_API_TOKEN' => first.token)
    _, _, err_b = post_capturing_audit(body, 'HTTP_X_OOD_API_TOKEN' => second.token)
    assert_match(/token_id=#{first.id}/, client_lines(err_a).join)
    assert_match(/token_id=#{second.id}/, client_lines(err_b).join)
  ensure
    Handlers::Audit.context = nil
    teardown_token_storage
  end

  # Past the bound on remembered clients, the first refusal is said once
  # rather than new clients going unrecorded without a trace.
  def test_reaching_the_client_limit_is_recorded_once
    OodApi.forget_mcp_clients!
    @keep_seen_clients = true
    OodApi::MCP_CLIENTS_SEEN_LIMIT.times { |i| OodApi.remember_mcp_client("c#{i}", '1', nil) }
    _, reply, first = post_capturing_audit(modern_body(1, { name: 'late', version: '1' }))
    _, _, second = post_capturing_audit(modern_body(2, { name: 'later', version: '1' }))
    assert reply['result']
    assert_empty client_lines(first + second)
    assert_equal 1, (first + second).lines.grep(/op=mcp_clients_limit /).length, first + second
  end

  # A client that sends `initialize` is recorded on every one, so it takes no
  # place among the remembered clients and cannot be the one that reaches
  # the bound.
  def test_legacy_initialize_takes_no_place_among_remembered_clients
    OodApi.forget_mcp_clients!
    @keep_seen_clients = true
    (OodApi::MCP_CLIENTS_SEEN_LIMIT - 1).times { |i| OodApi.remember_mcp_client("c#{i}", '1', nil) }
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: 'initialize',
                         params: { protocolVersion: '2025-06-18', capabilities: {},
                                   clientInfo: { name: 'probe', version: '9.9' } })
    _, _, legacy = post_capturing_audit(body)
    _, _, modern = post_capturing_audit(modern_body(2, { name: 'ood-agent', version: '2.0.1' }))
    assert_equal 1, client_lines(legacy).length, legacy
    assert_equal 1, client_lines(modern).length, modern
    refute_match(/op=mcp_clients_limit/, legacy + modern)
  end

  # The gem only validates the envelope of requests it dispatches, so these
  # reach the hook with `_meta` the gem never accepted. None is recorded.
  def test_unvalidated_envelopes_are_not_audited
    info = { name: 'ghost', version: '1' }
    [modern_body(1, info, method: 'no/such_method'),
     modern_body(nil, info, method: 'notifications/initialized')].each do |body|
      _, _, err = post_capturing_audit(body)
      assert_empty client_lines(err), body
    end
  end

  # The `_meta` noted for one request must not be read for the next: here the
  # first is refused before the gem runs, so a stale note would be recorded
  # against the second request, which carries no client info at all.
  def test_a_refused_requests_client_info_is_not_read_for_the_next_request
    OodApi.forget_mcp_clients!
    @keep_seen_clients = true
    _, refused, = post_capturing_audit(modern_body(1, { name: 'ghost', version: '1' }, method: 'prompts/list'))
    assert_equal(-32_601, refused.dig('error', 'code'))
    _, reply, err = post_capturing_audit(JSON.generate(jsonrpc: '2.0', id: 2, method: 'tools/list'))
    assert reply['result']
    assert_empty client_lines(err)
  end

  # A request with no body never reaches the gem, and leaves nothing noted
  # from an earlier request on the same thread.
  def test_a_request_without_a_body_clears_the_noted_client_info
    Thread.current[OodApi::MCP_REQUEST_META_KEY] = { 'stale' => true }
    request = Rack::Request.new(Rack::MockRequest.env_for('/', method: 'POST').tap { |env| env.delete('rack.input') })
    assert_nil request.body
    assert_nil OodApi.precheck_request_body(request)
    assert_nil Thread.current[OodApi::MCP_REQUEST_META_KEY]
  ensure
    Thread.current[OodApi::MCP_REQUEST_META_KEY] = nil
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
  # a uri, the others take none. A params object with a uri reaches the
  # transport.
  def test_resources_read_with_object_params_reaches_the_transport
    raw = '{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"ood://context"}}'
    status, code = mcp_post(raw)
    assert_equal 200, status, 'a resources/read with a uri must reach the transport'
    assert_nil code, 'a resources/read with a uri must not be refused'
  end

  # The mcp gem refuses a resources/read params object without a uri as
  # invalid params, not as an internal error.
  def test_resources_read_without_a_uri_is_invalid_params
    _status, code = mcp_post('{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{}}')
    assert_equal(-32_602, code)
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
