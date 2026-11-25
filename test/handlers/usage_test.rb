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
    ENV['USER'] = 'jesse'

    text = OodApi::Tools::GetQuotaAndBalanceTool.call(server_context: nil).content.first[:text]

    assert_includes text, '- /home (your quota), 12.0 GB of 50.0 GB used (24%), 40000 of 1000000 files (4%)'
    assert_includes text, '/fs/project (shared fileset), 1.0 TB of 2.0 TB used (50%), ' \
                          '100.0 GB of it yours, 10 files, no limit'
    assert_includes text, '- PAS1234: 1500 RU left'
  end

  def test_the_tool_says_when_the_site_publishes_nothing
    text = OodApi::Tools::GetQuotaAndBalanceTool.call(server_context: nil).content.first[:text]

    assert_equal 'This site does not publish storage quotas or allocation balances.', text
  end
end
