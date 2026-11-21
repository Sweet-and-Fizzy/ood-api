# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../app/mcp_server'

class CapabilitiesTest < Minitest::Test
  include TestHelpers

  SETTINGS = ['OOD_API_CAPABILITIES', 'OOD_API_DISABLE', 'OOD_API_REST', 'OOD_API_MCP'].freeze

  def setup
    @saved = ENV.to_h.slice(*SETTINGS, 'OOD_CONFIG_D_DIRECTORY')
    SETTINGS.each { |k| ENV.delete(k) }
    @dir = Dir.mktmpdir('ood-api-capabilities')
    ENV['OOD_CONFIG_D_DIRECTORY'] = @dir
    OodApi::SiteConfig.reset!
    OodApi::App.stubs(:clusters).returns([mock_cluster(id: 'cluster1')])
  end

  def teardown
    (SETTINGS + ['OOD_CONFIG_D_DIRECTORY']).each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(@dir)
    OodApi::SiteConfig.reset!
  end

  def caps
    OodApi::Capabilities
  end

  def listed_tools
    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list', params: {})
    JSON.parse(OodApi.build_mcp_server.handle_json(request)).dig('result', 'tools').map { |t| t['name'] }
  end

  def test_every_registered_tool_belongs_to_exactly_one_group
    assert_equal OodApi::MCP_TOOLS.map(&:name_value).sort, caps::ALL_TOOLS.sort
    assert_equal caps::ALL_TOOLS.size, caps::ALL_TOOLS.uniq.size
  end

  def test_a_fresh_install_is_read_only
    assert_equal caps::GROUPS['read'].sort, caps.enabled_tools.to_a.sort
    assert caps.rest?
    assert caps.mcp?
  end

  def test_read_only_tools_are_absent_from_the_mcp_tool_list
    tools = listed_tools

    assert_includes tools, 'read_file'
    ['submit_job', 'cancel_job', 'write_file', 'delete_file', 'create_directory'].each do |name|
      refute_includes tools, name
    end
  end

  def test_read_only_refuses_writes_over_rest_and_allows_reads
    get '/api/v1/clusters'
    assert last_response.ok?

    json = { 'CONTENT_TYPE' => 'application/json' }
    post '/api/v1/jobs', { cluster: 'cluster1', script: { content: 'x' } }.to_json, json
    assert_equal 403, last_response.status
    assert_match(/submit_job is not enabled/, json_response['message'])

    put '/api/v1/files?path=/tmp/x', 'data', json
    assert_equal 403, last_response.status
    delete '/api/v1/files?path=/tmp/x'
    assert_equal 403, last_response.status
    post '/api/v1/files?path=/tmp/x&type=directory', '{}', json
    assert_equal 403, last_response.status
    post '/api/v1/files?path=/tmp/x&touch=true', '{}', json
    assert_equal 403, last_response.status
    post '/api/v1/jobs/1/hold?cluster=cluster1', '{}', json
    assert_equal 403, last_response.status
    delete '/api/v1/jobs/1?cluster=cluster1'
    assert_equal 403, last_response.status
  end

  def test_groups_are_opted_into
    ENV['OOD_API_CAPABILITIES'] = 'jobs'

    assert caps.enabled?('submit_job')
    assert caps.enabled?('read_file'), 'read is always on'
    refute caps.enabled?('write_file')
  end

  def test_a_single_tool_can_be_removed_from_both_surfaces
    ENV['OOD_API_CAPABILITIES'] = 'all'
    ENV['OOD_API_DISABLE'] = 'cancel_job, list_historic_jobs'

    refute_includes listed_tools, 'cancel_job'
    assert_includes listed_tools, 'submit_job'
    delete '/api/v1/jobs/1?cluster=cluster1'
    assert_equal 403, last_response.status
    get '/api/v1/jobs/historic?cluster=cluster1'
    assert_equal 403, last_response.status
  end

  # A typo must not leave on the thing it was meant to remove, and there is
  # no telling what that was, so nothing is served until it is fixed.
  def test_an_unknown_name_turns_everything_off_and_is_reported
    ENV['OOD_API_CAPABILITIES'] = 'all'
    ENV['OOD_API_DISABLE'] = 'cancle_job'

    assert_empty caps.enabled_tools
    refute caps.rest?
    refute caps.mcp?
    assert_equal ['unknown tool "cancle_job"'], caps.problems

    ENV.delete('OOD_API_DISABLE')
    ENV['OOD_API_CAPABILITIES'] = 'read,job'
    refute caps.enabled?('list_jobs')
    assert_equal ['unknown capability "job"'], caps.problems
  end

  def test_a_misspelt_switch_or_key_turns_everything_off
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  mcp: flase\n")
    refute caps.mcp?
    refute caps.rest?
    assert_equal ['mcp must be true or false, not "flase"'], caps.problems

    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  disabled: [read_file]\n  rest: none\n")
    OodApi::SiteConfig.reset!
    assert_equal ['unknown setting ood_api.disabled', 'rest must be true or false, not "none"'], caps.problems
    refute caps.enabled?('read_file')
  end

  def test_misconfigured_settings_answer_503_on_both_surfaces_and_in_health
    ENV['OOD_API_DISABLE'] = 'cancle_job'

    get '/api/v1/clusters'
    assert_equal 503, last_response.status
    assert_equal 'misconfigured', JSON.parse(last_response.body)['error']
    status, = OodApi.mcp_rack_app.call(Rack::MockRequest.env_for('/', method: 'POST', input: '{}'))
    assert_equal 503, status
    get '/health'
    assert_equal 503, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'misconfigured', body['status']
    assert_equal ['unknown tool "cancle_job"'], body['problems']
  end

  def test_health_shows_the_settings_in_force
    ENV['OOD_API_DISABLE'] = 'read_file'
    ENV['OOD_API_MCP'] = 'off'

    get '/health'
    body = JSON.parse(last_response.body)
    assert_equal 'ok', body['status']
    assert_equal false, body['mcp']
    refute_includes body['tools'], 'read_file'
    assert_includes body['tools'], 'list_files'

    ENV['OOD_API_REST'] = '0'
    get '/health'
    assert last_response.ok?
    assert_equal 'disabled', JSON.parse(last_response.body)['status']
  end

  # An empty variable is what a templated env file leaves behind.
  def test_an_empty_variable_does_not_hide_the_file
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  disable: [read_file]\n  mcp: false\n")
    ENV['OOD_API_DISABLE'] = ''
    ENV['OOD_API_MCP'] = ' '

    refute caps.enabled?('read_file')
    refute caps.mcp?
  end

  # The file that could not be read may be the one that turned something off.
  def test_an_unreadable_settings_file_turns_everything_off
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  rest: <%= Configuration.nope %>\n")

    refute caps.rest?
    assert_equal ['ood_api.yml could not be read (NameError)'], caps.problems
  end

  def test_a_broken_file_about_something_else_is_only_skipped
    File.write(File.join(@dir, 'other.yml'), "pinned_apps: <%= Configuration.nope %>\n")

    assert caps.rest?
    assert_empty caps.problems
  end

  def test_settings_not_owned_by_root_are_a_problem_in_production
    skip 'runs as root' if Process.uid.zero?
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  rest: false\n")
    saved = ENV.fetch('RACK_ENV', nil)
    ENV['RACK_ENV'] = 'production'

    assert_equal ['ood_api.yml is not owned by root, or is writable by everyone'], caps.problems
    refute caps.rest?
  ensure
    ENV['RACK_ENV'] = saved
  end

  def test_app_tokens_can_be_required_from_the_settings_file
    refute OodApi::AppAuth.enabled?
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  app_tokens: true\n")
    OodApi::SiteConfig.reset!

    assert OodApi::AppAuth.enabled?
    assert_includes caps.summary, 'app_tokens=true'
    get '/api/v1/clusters'
    assert_equal 401, last_response.status
  end

  # Treating it as "off" would drop a requirement the site asked for.
  def test_an_app_token_setting_that_is_not_a_switch_turns_everything_off
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  app_tokens: required\n")

    assert_equal ['app_tokens must be true or false, not "required"'], caps.problems
    refute caps.rest?
  end

  def test_an_unknown_address_says_so
    get '/nope'

    assert_equal 404, last_response.status
    assert_equal 'not_found', JSON.parse(last_response.body)['error']
  end

  # What the site switched off in the Dashboard's file browser is off here.
  def test_the_dashboards_download_and_upload_switches_apply
    ENV['OOD_API_CAPABILITIES'] = 'all'
    File.write(File.join(@dir, 'files.yml'), "download_enabled: false\nupload_enabled: false\n")

    refute caps.enabled?('read_file')
    refute caps.enabled?('write_file')
    assert caps.enabled?('list_files')
    assert caps.enabled?('delete_file')
    assert_empty caps.problems
  end

  def test_the_dashboards_switches_are_read_from_its_env_file_too
    env_file = File.join(@dir, 'dashboard.env')
    File.write(env_file, "OOD_DOWNLOAD_ENABLED=false\n")
    ENV['OOD_DASHBOARD_ENV_FILE'] = env_file

    refute caps.enabled?('read_file')
    assert caps.enabled?('list_files')
  ensure
    ENV.delete('OOD_DASHBOARD_ENV_FILE')
  end

  def test_no_files_app_means_no_file_tools
    ENV['OOD_API_CAPABILITIES'] = 'all'
    apps = File.join(@dir, 'sys')
    FileUtils.mkdir_p(File.join(apps, 'dashboard'))
    ENV['OOD_API_SYS_APPS'] = apps

    assert_empty caps.enabled_tools.to_a & caps::FILE_TOOLS
    assert caps.enabled?('submit_job')

    FileUtils.mkdir_p(File.join(apps, 'files'))
    File.write(File.join(apps, 'files', 'manifest.yml'), 'name: Files')
    assert caps.enabled?('read_file')
  ensure
    ENV.delete('OOD_API_SYS_APPS')
  end

  def test_a_hidden_cluster_is_not_offered
    OodApi::App.stubs(:clusters).returns([mock_cluster(id: 'cluster1'), mock_cluster(id: 'secret', hidden: true)])

    get '/api/v1/clusters'
    assert_equal(['cluster1'], JSON.parse(last_response.body)['data'].map { |c| c['id'] })
    get '/api/v1/clusters/secret'
    assert_equal 404, last_response.status
  end

  # Each of these used to leave the app fully on although the file said off.
  def test_settings_that_would_silently_go_missing_turn_everything_off
    off = "  rest: false\n  mcp: false\n"
    {
      "ood_api:\n#{off}---\nother: 1\n".prepend("first: 1\n---\n") => /more than one YAML document/,
      "OOD_API:\n#{off}"                                           => /not as a top-level setting/,
      "ood-api:\n#{off}"                                           => /not as a top-level setting/,
      "production:\n  ood_api:\n  #{off.gsub("\n  ", "\n    ")}"   => /not as a top-level setting/,
      "- ood_api:\n  #{off.gsub("\n  ", "\n    ")}"                => /not as a top-level setting/,
      "ood_api:\n#{off}ood_api:\n  capabilities: all\n"            => /sets ood_api more than once/,
      "ood_api:\n  disable: [read_file]\n  disable: []\n"          => /sets ood_api.disable more than once/,
      "ood_api:\n#{off}".encode('UTF-16')                          => /not valid UTF-8/
    }.each do |content, problem|
      File.binwrite(File.join(@dir, 'ood_api.yml'), content)
      OodApi::SiteConfig.reset!

      assert_match problem, caps.problems.join("\n"), content.inspect
      refute caps.rest?, content.inspect
    end
  end

  # A later file would otherwise replace the earlier one's lists and switches.
  def test_ood_api_in_two_files_is_a_problem
    File.write(File.join(@dir, 'a.yml'), "ood_api:\n  disable: [read_file]\n")
    File.write(File.join(@dir, 'b.yml'), "ood_api:\n  # nothing yet\n")

    assert_equal ['ood_api is set in more than one file: a.yml, b.yml'], caps.problems
    refute caps.rest?
  end

  def test_a_file_that_only_mentions_the_app_in_a_value_or_comment_is_fine
    File.write(File.join(@dir, 'nav.yml'), "# ood_api: see ood_api.yml\npinned_apps:\n  - sys/ood-api\n")

    assert_empty caps.problems
    assert caps.rest?
  end

  def test_a_misspelt_variable_is_a_problem
    ENV['OOD_API_DISABEL'] = 'read_file'

    assert_equal ['unknown variable OOD_API_DISABEL'], caps.problems
    refute caps.rest?
  ensure
    ENV.delete('OOD_API_DISABEL')
  end

  def test_a_variable_that_names_nothing_does_not_hide_the_file
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  disable: [read_file]\n")
    ENV['OOD_API_DISABLE'] = ' , '

    refute caps.enabled?('read_file')
  end

  def test_a_variable_with_bad_bytes_is_a_problem_not_a_crash
    ENV['OOD_API_MCP'] = "fal\xFFse"

    refute caps.mcp?
    refute_empty caps.problems
  end

  def test_an_app_env_file_that_cannot_be_read_is_a_problem
    file = File.join(@dir, 'env')
    File.binwrite(file, "OOD_API_APP_TOKENS=true\nX=\xFF\n")
    OodApi::SiteConfig.load_app_env!(file)

    assert_match(/env could not be used/, caps.problems.join)
    refute caps.rest?
  ensure
    OodApi::SiteConfig.load_app_env!(File.join(@dir, 'absent'))
  end

  def test_names_are_matched_whatever_their_case
    ENV['OOD_API_CAPABILITIES'] = 'ALL'
    ENV['OOD_API_DISABLE'] = 'Delete_File'

    assert_empty caps.problems
    assert caps.enabled?('submit_job')
    refute caps.enabled?('delete_file')
  end

  def test_a_token_lifetime_that_is_not_a_number_is_a_problem
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  token_max_days: abc\n")

    assert_equal ['token_max_days must be a number of days, not "abc"'], caps.problems
  end

  def test_an_env_file_value_ends_at_a_comment
    file = File.join(@dir, 'env')
    File.write(file, "OOD_API_MCP=off # for now\nOOD_API_REST=\"on\" # quoted\n")
    OodApi::SiteConfig.load_app_env!(file)

    assert_empty caps.problems
    refute caps.mcp?
    assert caps.rest?
  ensure
    ENV.delete('OOD_API_MCP')
    ENV.delete('OOD_API_REST')
  end

  # Production prints errors before handling them unless told not to, and
  # that printing raised on a message that was not valid UTF-8.
  def test_sinatra_does_not_print_errors_before_they_are_handled
    refute OodApi::App.dump_errors?
  end

  def mcp_call(app, method, params = {})
    body = JSON.generate(jsonrpc: '2.0', id: 1, method: method, params: params)
    env = Rack::MockRequest.env_for('/', :method => 'POST', :input => body, 'CONTENT_TYPE' => 'application/json',
                                         'HTTP_ACCEPT' => 'application/json, text/event-stream')
    _status, _headers, chunks = app.call(env)
    text = +''
    chunks.each { |chunk| text << chunk }
    JSON.parse(text[/\{.*\}/m])
  end

  # The MCP server used to be built once, so a tool switched off afterwards
  # was still listed and still ran.
  def test_a_tool_switched_off_while_running_stops_working_over_mcp
    ENV['OOD_API_CAPABILITIES'] = 'all'
    app = OodApi.mcp_rack_app
    target = File.join(Dir.tmpdir, "ood-api-live-#{Process.pid}.txt")
    listed = mcp_call(app, 'tools/list').dig('result', 'tools').map { |tool| tool['name'] }
    assert_includes listed, 'write_file'

    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  disable: [write_file]\n")
    OodApi::SiteConfig.reset!

    listed = mcp_call(app, 'tools/list').dig('result', 'tools').map { |tool| tool['name'] }
    refute_includes listed, 'write_file'
    assert_includes listed, 'read_file'
    mcp_call(app, 'tools/call', name: 'write_file', arguments: { path: target, content: 'x' })
    refute File.exist?(target), 'a tool the site switched off still wrote the file'
  ensure
    FileUtils.rm_f(target) if target
  end

  # Whatever holds a reference to the tool, the tool itself says no.
  def test_a_disabled_tool_refuses_when_called_directly
    response = OodApi::Tools::WriteFileTool.call(path: '/tmp/nope.txt', content: 'x')

    assert response.error?
    assert_match(/not enabled/, response.content.first[:text])
    refute File.exist?('/tmp/nope.txt')
  end

  # The guide names this file for the app, so a slip like this is likely.
  def test_settings_written_without_the_ood_api_line_are_a_problem
    File.write(File.join(@dir, 'ood_api.yml'), "mcp: false\nrest: false\n")

    assert_equal ['ood_api.yml sets mcp at the top level; it belongs under ood_api'], caps.problems
    refute caps.rest?
  end

  def test_health_names_the_settings_held_by_the_environment
    ENV['OOD_API_MCP'] = 'true'

    get '/health'

    assert_equal ['OOD_API_MCP'], JSON.parse(last_response.body)['from_environment']
  end

  def test_a_call_to_a_tool_that_is_off_is_recorded_over_mcp
    app = OodApi.mcp_rack_app
    _out, err = capture_io do
      mcp_call(app, 'tools/call', name: 'write_file', arguments: { path: '/tmp/x', content: 'x' })
    end

    assert_match(/op=write_file user=\S+ source=mcp status=disabled/, err)
  end

  # None of these is about this app's settings, so none may switch it off.
  def test_other_content_that_mentions_the_app_changes_nothing
    [
      "dashboard_title: x # ood_api: see the other file\n",
      "announcement: \"ood-api: docs are at example.edu\"\n",
      "pinned_apps:\n  - sys/ood-api\n---\n",
      "nav_bar:\n  - title: \"ood_api: tools\"\n    url: /pun/sys/ood-api\n"
    ].each do |content|
      File.write(File.join(@dir, 'site.yml'), content)
      OodApi::SiteConfig.reset!

      assert_empty caps.problems, content.inspect
      assert caps.rest?, content.inspect
    end
  end

  def test_a_broken_file_that_only_lists_the_app_is_skipped_not_a_problem
    File.write(File.join(@dir, 'nav.yml'), "pinned_apps:\n  - sys/ood-api\n  - <%= Configuration.nope %>\n")

    assert_empty caps.problems
  end

  def test_a_query_string_that_cannot_be_parsed_is_a_bad_request
    get '/health', {}, { 'QUERY_STRING' => 'path=/tmp/100%' }
    assert_equal 400, last_response.status
    get '/api/v1/clusters', {}, { 'QUERY_STRING' => 'a=1&a[b]=2' }
    assert_equal 400, last_response.status
    assert_equal 'bad_request', JSON.parse(last_response.body)['error']
  end

  def test_a_surface_that_is_off_says_so
    ENV['OOD_API_REST'] = 'false'

    get '/api/v1/clusters'

    assert_equal 404, last_response.status
    assert_match(/REST API is not enabled/, JSON.parse(last_response.body)['message'])
  end

  def test_the_variable_bin_dev_reads_is_known
    ENV['OOD_API_DEV_BIND'] = '0.0.0.0'

    assert_empty caps.problems
  ensure
    ENV.delete('OOD_API_DEV_BIND')
  end

  def test_a_blank_or_zero_limit_means_the_default
    ENV['OOD_API_TEST_LIMIT'] = ''
    assert_equal 10, OodApi::SiteConfig.limit('OOD_API_TEST_LIMIT', 10)
    ENV['OOD_API_TEST_LIMIT'] = '0'
    assert_equal 10, OodApi::SiteConfig.limit('OOD_API_TEST_LIMIT', 10)
    ENV['OOD_API_TEST_LIMIT'] = ' 25 '
    assert_equal 25, OodApi::SiteConfig.limit('OOD_API_TEST_LIMIT', 10)
  ensure
    ENV.delete('OOD_API_TEST_LIMIT')
  end

  # The switch an admin reaches for: no PUN restart.
  def test_a_change_on_disk_is_picked_up_by_a_running_app
    assert caps.rest?

    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  rest: false\n  mcp: false\n")
    OodApi::SiteConfig.instance_variable_set(:@checked_at, nil)

    refute caps.rest?
    refute caps.mcp?
  end

  def test_settings_can_come_from_ondemand_d
    File.write(File.join(@dir, 'ood_api.yml'),
               "ood_api:\n  capabilities: [jobs, files_write]\n  disable:\n    - delete_file\n  mcp: false\n")

    assert caps.enabled?('submit_job')
    assert caps.enabled?('write_file')
    refute caps.enabled?('delete_file')
    refute caps.mcp?
    assert caps.rest?
  end

  def test_the_environment_wins_over_ondemand_d
    File.write(File.join(@dir, 'ood_api.yml'), "ood_api:\n  capabilities: all\n")
    ENV['OOD_API_CAPABILITIES'] = 'read'

    refute caps.enabled?('submit_job')
  end

  def test_each_surface_can_be_switched_off
    ENV['OOD_API_REST'] = 'false'
    get '/api/v1/clusters'
    assert_equal 404, last_response.status
    get '/health'
    assert last_response.ok?, 'the health check stays up'

    ENV['OOD_API_MCP'] = 'false'
    env = Rack::MockRequest.env_for('/', method: 'POST', input: '{}')
    status, = OodApi.mcp_rack_app.call(env)
    assert_equal 404, status
  end

  # Sinatra matches percent-encoded letters in a path. A check that matched
  # the path separately did not, and let these through in the read-only default.
  def test_percent_encoded_paths_do_not_get_round_the_check
    json = { 'CONTENT_TYPE' => 'application/json' }
    target = File.join(Dir.tmpdir, "ood-api-encoded-#{SecureRandom.hex(4)}")

    put "/api/v1/%66iles?path=#{target}", 'data', json
    assert_equal 403, last_response.status
    refute File.exist?(target)

    delete "/api/v1/file%73?path=#{target}"
    assert_equal 403, last_response.status
    post '/api/v1/%6aobs', { cluster: 'cluster1', script: { content: 'x' } }.to_json, json
    assert_equal 403, last_response.status
    post '/api/v1/jobs/1/%68old?cluster=cluster1', '{}', json
    assert_equal 403, last_response.status
  end

  # With every tool off, every route under /api/v1 must refuse. A route added
  # without naming its tool would answer here, so this fails until it does.
  def test_every_api_route_is_tied_to_a_tool
    ENV['OOD_API_DISABLE'] = OodApi::Capabilities::ALL_TOOLS.join(',')
    ungated = ['/api/v1/context']

    OodApi::App.routes.each do |verb, routes|
      next if verb == 'HEAD'

      routes.each do |pattern, _conditions, _block|
        path = pattern.to_s.gsub(/:\w+/, '1')
        next unless path.start_with?('/api/v1') && !ungated.include?(path)

        custom_request(verb, "#{path}?cluster=cluster1&path=/tmp/x", '{}', 'CONTENT_TYPE' => 'application/json')
        assert_equal 403, last_response.status, "#{verb} #{path} is not tied to a tool"
      end
    end
  end

  def test_routes_without_a_tool_are_not_gated
    get '/api/v1/context'

    refute_equal 403, last_response.status
  end
end
