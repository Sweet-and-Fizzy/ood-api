# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'stringio'
require_relative 'test_helper'
require_relative '../app/mcp_stdio'

# The MCP server on standard input and output. It skips the token and the
# browser checks, which have nothing to check here, and must keep everything
# else /mcp does: the site's settings, the request checks, the audit record.
class McpStdioTest < Minitest::Test
  include TestHelpers

  SETTINGS = ['OOD_API_CAPABILITIES', 'OOD_API_DISABLE', 'OOD_API_REST', 'OOD_API_MCP', 'OOD_API_LOCAL'].freeze
  ROOT = File.expand_path('..', __dir__)

  def setup
    @saved = ENV.to_h.slice(*SETTINGS, 'OOD_API_CONFIG_ROOT')
    SETTINGS.each { |k| ENV.delete(k) }
    @app = Dir.mktmpdir('ood-api-stdio-config')
    ENV['OOD_API_CONFIG_ROOT'] = @app
    OodApi::Stdio.instance_variable_set(:@server, nil)
    write_settings("local: true\n")
  end

  def teardown
    (SETTINGS + ['OOD_API_CONFIG_ROOT']).each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(@app)
    OodApi::SiteConfig.reset!
    Handlers::Audit.context = nil
  end

  def write_settings(text)
    File.binwrite(File.join(@app, 'config.yml'), text)
    OodApi::SiteConfig.reset!
  end

  def request(id, method, params = {})
    JSON.generate(jsonrpc: '2.0', id: id, method: method, params: params)
  end

  # @return [Array<Hash>] the replies to the given lines, in order
  def replies(*lines)
    output = StringIO.new
    OodApi::Stdio.serve(StringIO.new(lines.map { |line| "#{line}\n" }.join), output)
    output.string.lines.map { |line| JSON.parse(line) }
  end

  def tool_names
    replies(request(1, 'tools/list')).first.dig('result', 'tools').map { |tool| tool['name'] }
  end

  def test_it_lists_the_tools_the_site_has_on
    assert_includes tool_names, 'read_file'
    refute_includes tool_names, 'write_file'

    write_settings("local: true\ncapabilities: all\n")

    assert_includes tool_names, 'write_file'
  end

  def test_a_change_to_the_settings_reaches_a_server_that_is_already_running
    input, feed = IO.pipe
    output = StringIO.new
    server = Thread.new { OodApi::Stdio.serve(input, output) }
    feed.puts request(1, 'tools/list')
    sleep 0.05 until output.string.count("\n") == 1
    write_settings("local: true\ncapabilities: all\n")
    feed.puts request(2, 'tools/list')
    sleep 0.05 until output.string.count("\n") == 2
    write_settings("local: true\ncapabilities: all\ndisable: [write_file]\n")
    feed.puts request(3, 'tools/list')
    feed.puts request(4, 'tools/call', name: 'write_file', arguments: { path: '/tmp/x', content: 'x' })
    feed.close
    capture_io { server.join }

    replies = output.string.lines.map { |line| JSON.parse(line) }
    first, second, third = replies.first(3).map { |reply| reply.dig('result', 'tools').map { |t| t['name'] } }
    refute_includes first, 'write_file'
    assert_includes second, 'write_file'
    refute_includes third, 'write_file'
    assert_match(/Tool not found/, replies.last.dig('error', 'data'))
  end

  def test_each_reply_carries_the_id_of_its_request
    first, second = replies(request('a', 'ping'), request(7, 'tools/list'))

    assert_equal 'a', first['id']
    assert_equal 7, second['id']
  end

  def test_a_notification_and_a_blank_line_get_no_reply
    lines = replies(JSON.generate(jsonrpc: '2.0', method: 'notifications/initialized'), '', request(1, 'ping'))

    assert_equal([1], lines.map { |line| line['id'] })
  end

  def test_a_tool_that_is_off_is_not_run_and_the_call_is_recorded
    reply = nil
    _out, err = capture_io do
      reply = replies(request(1, 'tools/call', name: 'write_file', arguments: { path: '/tmp/x', content: 'x' })).first
    end

    assert_match(/Tool not found/, reply.dig('error', 'data'))
    assert_match(/op=write_file user=\S+ source=mcp status=disabled transport=stdio/, err)
  end

  def test_records_say_the_call_came_over_stdio
    _out, err = capture_io { replies(request(1, 'tools/call', name: 'list_env', arguments: {})) }

    assert_match(/op=list_env .*transport=stdio/, err)
  end

  # The 2026-07-28 protocol has no `initialize`; the client names itself on
  # every request. One connection is one process, so it is recorded once.
  def test_a_stateless_client_is_recorded_once_per_connection
    OodApi.forget_mcp_clients!
    meta = { 'io.modelcontextprotocol/protocolVersion'    => '2026-07-28',
             'io.modelcontextprotocol/clientCapabilities' => {},
             'io.modelcontextprotocol/clientInfo'         => { name: 'ood-agent', version: '2.0.1' } }
    result = nil
    _out, err = capture_io do
      result = replies(request(1, 'tools/list', _meta: meta),
                       request(2, 'tools/call', name: 'list_env', arguments: {}, _meta: meta))
    end

    assert(result.all? { |reply| reply['result'] }, result.inspect)
    lines = err.lines.grep(/op=mcp_initialize/)
    assert_equal 1, lines.length, err
    assert_match(/client=ood-agent client_version=2\.0\.1 protocol_version=2026-07-28 transport=stdio/, lines.first)
  end

  # Over stdio nothing checks the envelope before the gem, and the gem does not
  # read it for a method it has no handler for, for a notification, or for
  # `server/discover` on a connection that has not chosen the new protocol,
  # even when it names the new protocol but leaves out part of the envelope.
  # Client info carried that way is never recorded.
  def test_client_info_the_server_never_accepted_is_not_recorded
    OodApi.forget_mcp_clients!
    meta = { 'io.modelcontextprotocol/protocolVersion'    => '1999-01-01',
             'io.modelcontextprotocol/clientCapabilities' => {},
             'io.modelcontextprotocol/clientInfo'         => { name: 'ghost', version: '1' } }
    modern = meta.merge('io.modelcontextprotocol/protocolVersion' => '2026-07-28')
    partial = modern.except('io.modelcontextprotocol/clientCapabilities')
    notification = JSON.generate(jsonrpc: '2.0', method: 'notifications/initialized', params: { _meta: modern })
    _out, err = capture_io do
      replies(request(1, 'server/discover', _meta: meta), request(2, 'no/such_method', _meta: modern), notification,
              request(3, 'server/discover', _meta: partial))
    end

    assert_empty err.lines.grep(/op=mcp_initialize/), err
  end

  def test_nothing_is_served_until_the_site_switches_it_on
    write_settings('')
    reply = replies(request(1, 'tools/list')).first

    assert_equal 1, reply['id']
    assert_equal 'Local programs are not served at this site', reply.dig('error', 'message')
  end

  # A site can serve an assistant of its own and no client from outside, or
  # the other way round.
  def test_the_switch_is_separate_from_the_one_for_the_mcp_endpoint
    write_settings("local: true\nmcp: false\nrest: false\n")

    assert_includes tool_names, 'read_file'
    refute OodApi::Capabilities.mcp?

    write_settings("mcp: true\n")

    assert OodApi::Capabilities.mcp?
    assert_nil replies(request(1, 'tools/list')).first['result']
  end

  def test_nothing_is_served_when_the_settings_are_not_understood
    write_settings("local: true\ncapabilites: all\n")
    reply = replies(request(1, 'tools/call', name: 'list_env', arguments: {})).first

    assert_match(/could not be understood/, reply.dig('error', 'message'))
    assert_nil reply['result']
  end

  def test_a_notification_is_not_answered_even_when_switched_off
    write_settings("local: false\n")

    assert_empty replies(JSON.generate(jsonrpc: '2.0', method: 'notifications/initialized'))
  end

  def test_malformed_requests_are_refused_as_they_are_over_http
    call = ->(params) { JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: params) }
    cases = {
      call.call([1])                                                                   => -32_602,
      call.call(name: 'list_env', arguments: [])                                       => -32_602,
      call.call(name: 'list_env', _meta: 1)                                            => -32_602,
      call.call(name: 'read_file', arguments: { size: 'HUGE' }).sub('"HUGE"', '1e400') => -32_602,
      request(1, 'prompts/list')                                                       => -32_601
    }
    cases.each do |line, code|
      reply = replies(line).first

      assert_equal code, reply.dig('error', 'code'), line
      assert_equal 1, reply['id'], line
    end
  end

  # /mcp takes one request to a body. A batch would reach the server without
  # the checks above, and a call in it to a tool that is off would go
  # unrecorded.
  def test_a_batch_is_refused_whole
    batch = "[#{request(1, 'tools/call', name: 'write_file', arguments: { path: '/tmp/x', content: 'x' })}]"
    reply = nil
    _out, err = capture_io { reply = replies(batch, '[]', '7').map { |line| line.dig('error', 'code') } }

    assert_equal [-32_600, -32_600, -32_600], reply
    refute_match(/op=write_file/, err)
  end

  def test_bytes_that_are_not_text_do_not_lose_the_request
    reply = replies(%({"jsonrpc":"2.0","id":3,"method":"ping","params":{"x":"\xff"}}).b).first

    assert_equal 3, reply['id']
    assert_equal({}, reply['result'])
  end

  def test_a_line_that_is_not_json_is_answered_with_a_parse_error
    reply = replies('{not json').first

    assert_equal(-32_700, reply.dig('error', 'code'))
  end

  def test_a_line_longer_than_any_request_ends_the_session
    OodApi.stubs(:max_request_bytes).returns(64)
    lines = replies('x' * 200, request(1, 'ping'))

    assert_equal 1, lines.size
    assert_equal 'Request too large', lines.first.dig('error', 'message')
  end

  def test_a_failure_inside_the_server_is_an_error_reply_not_a_dead_process
    OodApi.stubs(:build_mcp_server).raises(NotImplementedError)
    reply = nil
    _out, err = capture_io { reply = replies(request(5, 'tools/list')).first }

    assert_equal 5, reply['id']
    assert_equal(-32_603, reply.dig('error', 'code'))
    assert_match(/op=mcp_request_failed .*error=NotImplementedError/, err)
  end

  LIST = %({"jsonrpc":"2.0","id":1,"method":"tools/list"}\n)

  # Runs bin/mcp-stdio as a separate process.
  #
  # @return [Array(Hash, String)] its last reply and what it logged
  def run_script(env, script: File.join(ROOT, 'bin', 'mcp-stdio'), chdir: Dir.tmpdir, input: LIST)
    clean = { 'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil, 'RACK_ENV' => nil, 'RAILS_ENV' => nil,
              'PASSENGER_BASE_URI' => nil, 'OOD_API_CONFIG_ROOT' => nil, 'OOD_API_LOCAL' => nil }
    out, err, status = Open3.capture3(clean.merge(env), script, stdin_data: input, chdir: chdir)
    assert status.success?, err
    [JSON.parse(out.lines.last), err]
  end

  # A Passenger app hands its children RUBYOPT and its own base URI. Started
  # that way, from that app's directory, the script still has to load this
  # app's gems and read this app's settings.
  def test_the_script_runs_when_started_by_another_passenger_app
    Dir.mktmpdir('another-app') do |elsewhere|
      reply, err = run_script({ 'RUBYOPT' => '-r bundler/setup', 'RACK_ENV' => 'development',
                                'PASSENGER_BASE_URI' => '/pun/sys/another-app', 'OOD_API_LOCAL' => 'true' },
                              chdir: elsewhere)

      assert_includes reply.dig('result', 'tools').map { |tool| tool['name'] }, 'read_file'
      assert_match(%r{settings="/etc/ood/config/apps/#{File.basename(ROOT)}/config.yml}, err)
    end
  end

  # The script loads the tools without the web app, so this runs it as its
  # own process: in this test process the web app is already loaded.
  def test_the_script_reads_the_sites_clusters_for_the_cluster_and_job_tools
    Dir.mktmpdir('clusters') do |clusters|
      File.write(File.join(clusters, 'hpc.yml'), <<~YAML)
        v2:
          metadata:
            title: Test HPC
          login:
            host: login.example.edu
          job:
            adapter: slurm
      YAML
      env = { 'RACK_ENV' => 'development', 'OOD_API_LOCAL' => 'true', 'OOD_CLUSTERS' => clusters }
      call = lambda do |name, arguments|
        "#{JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: name, arguments: arguments })}\n"
      end

      reply, err = run_script(env, input: call.call('list_clusters', {}))

      assert reply.key?('result'), "#{reply['error']}\n#{err}"
      assert_equal false, reply.dig('result', 'isError')
      assert_match(/hpc \(Test HPC\)/, reply.dig('result', 'content', 0, 'text'))

      # A job tool reaches the cluster's scheduler. Whether the scheduler
      # answers depends on the host, but the reply is the tool's own.
      reply, err = run_script(env, input: call.call('list_jobs', { cluster_id: 'hpc' }))

      assert reply.key?('result'), "#{reply['error']}\n#{err}"
    end
  end

  def test_a_missing_clusters_directory_is_a_tool_error_not_a_protocol_error
    Dir.mktmpdir('clusters') do |dir|
      missing = File.join(dir, 'missing')
      env = { 'RACK_ENV' => 'development', 'OOD_API_LOCAL' => 'true', 'OOD_CLUSTERS' => missing }
      input = "#{JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                               params: { name: 'list_clusters', arguments: {} })}\n"

      reply, err = run_script(env, input: input)

      assert reply.key?('result'), "#{reply['error']}\n#{err}"
      assert_equal true, reply.dig('result', 'isError')
      assert_includes reply.dig('result', 'content', 0, 'text'), missing
    end
  end

  def test_the_script_can_be_started_by_a_relative_path
    reply, = run_script({ 'RACK_ENV' => 'development', 'OOD_API_LOCAL' => 'true' },
                        script: File.join(File.basename(ROOT), 'bin', 'mcp-stdio'), chdir: File.dirname(ROOT))

    assert reply['result']
  end

  # Passenger names an app by the directory it is served from, link or not,
  # and the settings directory has that name.
  def test_an_install_through_a_link_reads_the_settings_named_after_the_link
    Dir.mktmpdir('apps') do |apps|
      File.symlink(ROOT, File.join(apps, 'site-api'))
      _reply, err = run_script({ 'RACK_ENV' => 'development' },
                               script: File.join(apps, 'site-api', 'bin', 'mcp-stdio'))

      assert_match(%r{settings="/etc/ood/config/apps/site-api/config.yml}, err)
    end
  end

  # The test's settings file belongs to whoever runs the tests, which is
  # what a file planted by a user looks like.
  def test_started_with_no_environment_named_the_settings_must_be_roots
    skip 'the settings file is root-owned when the tests run as root' if Process.uid.zero?
    write_settings("local: true\ncapabilities: all\n")
    [{}, { 'RACK_ENV' => '' }, { 'RAILS_ENV' => 'development' }].each do |env|
      reply, err = run_script(env.merge('OOD_API_CONFIG_ROOT' => @app))

      assert_match(/could not be understood/, reply.dig('error', 'message'), env.inspect)
      assert_match(/not owned by root/, err, env.inspect)
    end

    reply, = run_script({ 'RACK_ENV' => 'development', 'OOD_API_CONFIG_ROOT' => @app })

    assert_includes reply.dig('result', 'tools').map { |tool| tool['name'] }, 'write_file'
  end
end
