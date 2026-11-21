# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/site_config'

class SiteConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('ood-api-site-config')
    @saved = ENV.to_h.slice('OOD_ALLOWLIST_PATH', 'WHITELIST_PATH', 'OOD_CONFIG_D_DIRECTORY',
                            'OOD_DASHBOARD_ENV_FILE')
    ENV['OOD_DASHBOARD_ENV_FILE'] = File.join(@dir, 'dashboard.env')
    ENV.delete('OOD_ALLOWLIST_PATH')
    ENV.delete('WHITELIST_PATH')
    ENV['OOD_CONFIG_D_DIRECTORY'] = @dir
    OodApi::SiteConfig.reset!
  end

  def teardown
    ['OOD_ALLOWLIST_PATH', 'WHITELIST_PATH', 'OOD_CONFIG_D_DIRECTORY',
     'OOD_DASHBOARD_ENV_FILE'].each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
    FileUtils.rm_rf(@dir)
    OodApi::SiteConfig.reset!
  end

  def test_no_allowlist_by_default
    assert_empty OodApi::SiteConfig.allowlist_paths
  end

  def test_allowlist_from_the_environment
    ENV['OOD_ALLOWLIST_PATH'] = '/home:/scratch'

    assert_equal ['/home', '/scratch'], OodApi::SiteConfig.allowlist_paths.map(&:to_s)
  end

  def test_allowlist_from_ondemand_d
    File.write(File.join(@dir, 'files.yml'), "allowlist_path:\n  - /home\n  - /project:/scratch\n")

    assert_equal ['/home', '/project', '/scratch'], OodApi::SiteConfig.allowlist_paths.map(&:to_s)
  end

  def test_environment_wins_over_ondemand_d
    File.write(File.join(@dir, 'files.yml'), "allowlist_path: /from-file\n")
    ENV['OOD_ALLOWLIST_PATH'] = '/from-env'

    assert_equal ['/from-env'], OodApi::SiteConfig.allowlist_paths.map(&:to_s)
  end

  # Where sites set it today: only the Dashboard process loads this file.
  def test_allowlist_from_the_dashboard_env_file
    File.write(File.join(@dir, 'dashboard.env'),
               "# files\nOOD_BRAND=x\nexport OOD_ALLOWLIST_PATH=\"/home:/scratch\"\n")

    assert_equal ['/home', '/scratch'], OodApi::SiteConfig.allowlist_paths.map(&:to_s)
  end

  def test_dashboard_env_file_wins_over_ondemand_d
    File.write(File.join(@dir, 'files.yml'), "allowlist_path: /from-file\n")
    File.write(File.join(@dir, 'dashboard.env'), "OOD_ALLOWLIST_PATH=/from-dashboard-env\n")

    assert_equal ['/from-dashboard-env'], OodApi::SiteConfig.allowlist_paths.map(&:to_s)
  end

  def test_erb_files_are_rendered
    File.write(File.join(@dir, 'files.yml.erb'), "allowlist_path: <%= '/render' + 'ed' %>\n")

    assert_equal ['/rendered'], OodApi::SiteConfig.allowlist_paths.map(&:to_s)
  end

  def test_an_unreadable_config_does_not_raise
    File.write(File.join(@dir, 'broken.yml'), "allowlist_path: [unclosed\n")

    assert_empty OodApi::SiteConfig.allowlist_paths
  end
end
