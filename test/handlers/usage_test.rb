# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/usage'
require_relative '../../app/mcp_tools/usage'

class HandlersUsageTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('ood-usage')
    @saved = ENV.to_h.slice('OOD_QUOTA_PATH', 'OOD_BALANCE_PATH', 'USER')
    ENV.delete('OOD_QUOTA_PATH')
    ENV.delete('OOD_BALANCE_PATH')
    OodApi::SiteConfig.stubs(:dashboard_env).returns({})
  end

  def teardown
    ['OOD_QUOTA_PATH', 'OOD_BALANCE_PATH', 'USER'].each { |k| @saved[k] ? ENV[k] = @saved[k] : ENV.delete(k) }
    FileUtils.rm_rf(@dir)
  end

  def write(name, data)
    path = File.join(@dir, name)
    File.write(path, JSON.generate(data))
    path
  end

  def quota_file
    write('quota.json', 'version' => 1, 'timestamp' => 1_700_000_000, 'quotas' => [
            { 'type' => 'user', 'user' => 'jesse', 'path' => '/home', 'total_block_usage' => 12_582_912,
              'block_limit' => 52_428_800, 'total_file_usage' => 40_000, 'file_limit' => 1_000_000 },
            { 'type' => 'fileset', 'user' => 'jesse', 'path' => '/fs/project', 'total_block_usage' => 1_073_741_824,
              'block_usage' => 104_857_600, 'block_limit' => 2_147_483_648,
              'total_file_usage' => 10, 'file_limit' => 0 },
            { 'type' => 'user', 'user' => 'someone-else', 'path' => '/home', 'total_block_usage' => 1,
'block_limit' => 2 }
          ])
  end

  def test_the_users_quotas_are_read_and_nobody_elses
    ENV['OOD_QUOTA_PATH'] = quota_file

    quotas = Handlers::Usage.for('jesse')[:quotas]

    assert_equal ['/home', '/fs/project'], quotas.map(&:path)
    assert_equal 12_582_912 * 1024, quotas.first.used_bytes
    assert_equal 104_857_600 * 1024, quotas.last.user_bytes
    assert_equal Time.at(1_700_000_000).iso8601, quotas.first.updated_at
  end

  def test_balances_and_several_paths_are_read_and_a_missing_file_is_skipped
    balance = write('balance.json', 'version' => 1, 'timestamp' => 1_700_000_000,
                                    'config' => { 'unit' => 'RU', 'project_type' => 'project' },
                                    'balances' => [{ 'user' => 'jesse', 'project' => 'PAS1234', 'value' => 1500.7 }])
    ENV['OOD_QUOTA_PATH'] = "#{File.join(@dir, 'missing.json')}:#{quota_file}"
    ENV['OOD_BALANCE_PATH'] = balance

    usage = Handlers::Usage.for('jesse')

    assert_equal 2, usage[:quotas].size
    assert_equal([['PAS1234', 1500, 'RU']], usage[:balances].map { |b| [b.project, b.value, b.unit] })
  end

  def test_a_url_keeps_its_port
    ENV['OOD_QUOTA_PATH'] = '/a.json:http://127.0.0.1:8080/q.json:https://x.edu/b.json'
    assert_equal ['/a.json', 'http://127.0.0.1:8080/q.json', 'https://x.edu/b.json'], Handlers::Usage.paths('OOD_QUOTA_PATH')
  end

  def test_a_url_keeps_its_colon
    assert_equal ['https://usage.example.edu/quota.json', '/tmp/b.json'],
                 (ENV['OOD_QUOTA_PATH'] = 'https://usage.example.edu/quota.json:/tmp/b.json'
                  Handlers::Usage.paths('OOD_QUOTA_PATH'))
  end

  def test_a_site_with_neither_path_is_not_configured
    refute Handlers::Usage.for('jesse')[:configured]
  end

  def test_the_tool_reports_space_files_shares_and_balances_plainly
    ENV['OOD_QUOTA_PATH'] = quota_file
    balances = [{ 'user' => 'jesse', 'project' => 'PAS1234', 'value' => 1500 }]
    ENV['OOD_BALANCE_PATH'] = write('b.json', 'config' => { 'unit' => 'RU' }, 'balances' => balances)
    OodApi::Tools::GetQuotaAndBalanceTool.stubs(:account).returns('jesse')

    text = OodApi::Tools::GetQuotaAndBalanceTool.call(server_context: nil).content.first[:text]

    assert_includes text, '- /home (your quota), 12.0 GB of 50.0 GB used (24%), 40000 of 1000000 files (4%)'
    assert_includes text, '/fs/project (shared fileset), 1.0 TB of 2.0 TB used (50%), ' \
                          '100.0 GB of it yours, 10 files, no limit'
    assert_includes text, '- PAS1234: 1500 RU left'
  end

  def test_an_unreadable_source_is_reported_not_taken_as_no_quotas
    ENV['OOD_QUOTA_PATH'] = "#{File.join(@dir, 'missing.json')}:#{write('bad.json', [1, 2])}"
    OodApi::Tools::GetQuotaAndBalanceTool.stubs(:account).returns('jesse')

    text = OodApi::Tools::GetQuotaAndBalanceTool.call(server_context: nil).content.first[:text]

    assert_includes text, 'No storage quotas are listed for you.'
    assert_includes text, "2 of the site's quota sources could not be read"
  end

  def test_odd_values_do_not_break_a_quota
    path = File.join(@dir, 'q.json')
    File.write(path, '{"quotas": [{"user": "jesse", "path": "/home\\nForged line", "type": null, ' \
                     '"total_block_usage": 1, "block_limit": 1e400}]}')
    ENV['OOD_QUOTA_PATH'] = path
    OodApi::Tools::GetQuotaAndBalanceTool.stubs(:account).returns('jesse')
    quota = Handlers::Usage.for('jesse')[:quotas].first
    assert_equal ['user', nil], [quota.type, quota.limit_bytes]

    text = OodApi::Tools::GetQuotaAndBalanceTool.call(server_context: nil).content.first[:text]
    assert_includes text, '- /home Forged line (your quota), 1.0 KB used, no limit'
  end

  def test_a_url_is_read_in_pieces_and_cut_off_past_the_limit
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.stubs(:read_body).multiple_yields(['{"quotas":'], ['[]}'])
    assert_equal '{"quotas":[]}', Handlers::Usage.body(response, Float::INFINITY)

    assert_raises(Handlers::Usage::Unreadable) { Handlers::Usage.body(response, Float::INFINITY, 4) }
    assert_raises(Handlers::Usage::Unreadable) { Handlers::Usage.body(response, 0) }
  end

  def test_a_failed_response_is_unreadable
    http = mock('http')
    http.stubs(:request).yields(Net::HTTPInternalServerError.new('1.1', '500', 'Error'))
    Net::HTTP.stubs(:start).yields(http)

    assert_nil Handlers::Usage.read('https://usage.example.edu/quota.json')
  end

  def test_the_tool_says_when_the_site_publishes_nothing
    text = OodApi::Tools::GetQuotaAndBalanceTool.call(server_context: nil).content.first[:text]

    assert_equal 'This site does not publish storage quotas or allocation balances.', text
  end
end
