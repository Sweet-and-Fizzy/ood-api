# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/api_token'

# The Dashboard supplies ActiveModel; nothing else in the plugin's model
# depends on Rails, so a stand-in is enough to load it here.
module ActiveModel
  module Model; end
end
require_relative '../dashboard-plugin/lib/api_token'
# Loading the plugin tells the API's code it is running inside the
# Dashboard. That holds only for the tests below.
OodApi::SiteConfig.hosted_by_dashboard!(nil)

# The token page's model. What it creates the API must accept, and what the
# API enforces it must show.
class DashboardPluginTest < Minitest::Test
  include TestHelpers

  def setup
    setup_token_storage
    @app = Dir.mktmpdir('ood-api-plugin-config')
    OodApi::SiteConfig.hosted_by_dashboard!(@app)
    OodApi::SiteConfig.reset!
  end

  def teardown
    teardown_token_storage
    FileUtils.rm_rf(@app)
    OodApi::SiteConfig.hosted_by_dashboard!(nil)
    OodApi::SiteConfig.reset!
  end

  def settings(text)
    File.write(File.join(@app, 'config.yml'), text)
    OodApi::SiteConfig.reset!
  end

  def test_a_token_made_on_the_page_is_one_the_api_accepts
    token, plain = ApiToken.generate(name: 'laptop', lifetime: '30')

    found = OodApi::ApiToken.find_by_token(plain)

    assert_equal token.id, found.id
    refute found.expired?
    assert_equal ['laptop'], ApiToken.all.map(&:name)
    refute_includes File.read(OodApi::ApiToken::TOKENS_FILE), plain
  end

  def test_revoking_on_the_page_revokes_it_for_the_api
    token, plain = ApiToken.generate(name: 'ci')

    ApiToken.find(token.id).destroy

    assert_nil OodApi::ApiToken.find_by_token(plain)
    assert_empty ApiToken.all
  end

  def test_the_page_offers_what_the_site_allows
    assert_equal ['30', '90', '365'], ApiToken.lifetime_options
    assert_equal '90', ApiToken.default_lifetime

    settings("token_max_days: 45\ntoken_allow_never: true\n")
    assert_equal ['30', '45', 'never'], ApiToken.lifetime_options
    assert_equal '45', ApiToken.default_lifetime
    assert_nil ApiToken.expiry_for('never')
  end

  # The Dashboard never loads the API's env file, so the page reads it.
  def test_the_page_reads_the_apis_env_file_as_the_api_does
    File.write(File.join(@app, 'env'), "OOD_API_TOKEN_MAX_DAYS=\" 60 \" # two months\n")

    assert_equal 60, ApiToken.max_days
    assert_equal ['30', '60'], ApiToken.lifetime_options
  end

  def test_a_lifetime_the_page_did_not_offer_gets_the_site_maximum
    settings("token_max_days: 45\n")

    expiry = Time.iso8601(ApiToken.expiry_for('365'))

    assert_in_delta Time.now + (45 * 86_400), expiry, 5
    assert_nil(ApiToken.expiry_for('never').then { |value| value && nil })
  end

  # The directory is named after where the plugin's link points, one step.
  def test_the_config_directory_takes_the_name_the_api_is_installed_under
    Dir.mktmpdir('ood-api-plugin-link') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'sys', 'api', 'dashboard-plugin'))
      link = File.join(dir, 'plugins', 'ood-api')
      FileUtils.mkdir_p(File.dirname(link))
      File.symlink(File.join(dir, 'sys', 'api', 'dashboard-plugin'), link)

      assert_equal '/etc/ood/config/apps/api', ApiToken.config_root_for(link)
      assert_equal '/etc/ood/config/apps/ood-api', ApiToken.config_root_for(File.join(dir, 'sys', 'api'))
    end
  end

  # `false` is not a time, and is not "never" either.
  def test_an_expiry_that_is_not_a_time_is_replaced
    FileUtils.mkdir_p(OodApi::ApiToken::TOKENS_DIR)
    plain = 'a' * 64
    File.write(OodApi::ApiToken::TOKENS_FILE,
               JSON.generate([{ id: '1', name: 'edited', token_digest: OodApi::ApiToken.digest(plain),
                                created_at: Time.now.iso8601, expires_at: false }]))

    OodApi::ApiToken.touch(OodApi::ApiToken.find_by_token(plain))

    stored = JSON.parse(File.read(OodApi::ApiToken::TOKENS_FILE)).first['expires_at']
    assert_kind_of String, stored
    assert_in_delta Time.now + (365 * 86_400), Time.iso8601(stored), 60
  end

  def test_a_hand_written_timestamp_does_not_break_the_page
    token = ApiToken.new(id: '1', name: 'x', created_at: 'yesterday-ish', expires_at: nil)

    assert_equal 'yesterday-ish', token.created_at_display
    assert_equal 'Never', token.expires_at_display('Never')
    refute token.expired?
  end
end
