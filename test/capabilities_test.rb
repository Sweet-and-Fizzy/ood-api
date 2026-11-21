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

  # A typo must not leave the tool it was meant to remove switched on.
  def test_an_unknown_name_falls_back_to_read_only_and_is_reported
    ENV['OOD_API_CAPABILITIES'] = 'all'
    ENV['OOD_API_DISABLE'] = 'cancle_job'

    assert_equal caps::GROUPS['read'].sort, caps.enabled_tools.to_a.sort
    assert_equal ['unknown tool "cancle_job"'], caps.problems

    ENV.delete('OOD_API_DISABLE')
    ENV['OOD_API_CAPABILITIES'] = 'read,job'
    refute caps.enabled?('submit_job')
    assert_equal ['unknown capability "job"'], caps.problems
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
