# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'

# Start coverage before any application code is required so every line is
# tracked. Skipped when NOCOV is set (e.g. for a quick local run).
unless ENV['NOCOV']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/test/'
    add_filter '/vendor/'
    track_files '{app,lib}/**/*.rb'

    # Ratcheting floor: fail the full suite if coverage drops below the
    # current level. Raise this as coverage improves; never lower it.
    # Only enforced for a full run (a single-file run can't hit the bar).
    minimum_coverage(line: 91) if ENV['COVERAGE_ENFORCE']
  end
end

require 'minitest/autorun'
require 'rack/test'
require 'mocha/minitest'

# Never read a real site's settings: this suite may run on an OOD host.
ENV['OOD_CONFIG_D_DIRECTORY'] = File.join(Dir.tmpdir, 'ood-api-no-such-config')
ENV['OOD_DASHBOARD_ENV_FILE'] = File.join(Dir.tmpdir, 'ood-api-no-such-env')
ENV['OOD_API_CONFIG_ROOT'] = File.join(Dir.tmpdir, 'ood-api-no-such-app-config')

# The suite exercises every tool; the read-only default has its own tests.
ENV['OOD_API_CAPABILITIES'] = 'all'
['OOD_API_DISABLE', 'OOD_API_REST', 'OOD_API_MCP'].each { |k| ENV.delete(k) }
['OOD_ALLOWLIST_PATH', 'WHITELIST_PATH'].each { |k| ENV.delete(k) }
require 'json'
require 'fileutils'
require 'securerandom'

# Load the app
require_relative '../app/api'
require_relative '../lib/api_token'

module TestHelpers
  include Rack::Test::Methods

  def app
    OodApi::App
  end

  # App tokens go in their own header — Apache owns Authorization.
  def auth_header(token)
    { 'HTTP_X_OOD_API_TOKEN' => token.token }
  end

  def json_response
    JSON.parse(last_response.body)
  end

  def setup_token_storage
    @test_token_dir = File.join(Dir.tmpdir, "ood_api_test_#{SecureRandom.hex(4)}")
    @test_token_file = File.join(@test_token_dir, 'tokens.json')

    # Override the constants
    # LOCK_FILE must be redirected too, or tests contend on the real
    # ~/.config/ondemand lock and serialise against the developer's own PUN.
    [:TOKENS_DIR, :TOKENS_FILE, :LOCK_FILE].each do |c|
      OodApi::ApiToken.send(:remove_const, c) if OodApi::ApiToken.const_defined?(c)
    end
    OodApi::ApiToken.const_set(:TOKENS_DIR, @test_token_dir)
    OodApi::ApiToken.const_set(:TOKENS_FILE, @test_token_file)
    OodApi::ApiToken.const_set(:LOCK_FILE, File.join(@test_token_dir, '.tokens.json.lock'))

    # Tests in this suite exercise the opt-in app-token flow; the default
    # trust-PUN mode is covered by dedicated tests that unset this var.
    ENV['OOD_API_APP_TOKENS'] = 'true'
  end

  def teardown_token_storage
    FileUtils.rm_rf(@test_token_dir) if @test_token_dir && File.exist?(@test_token_dir)
    ENV.delete('OOD_API_APP_TOKENS')
  end

  def create_test_token(name = 'Test Token')
    token, plain = OodApi::ApiToken.create(name: name)
    # The store keeps only a digest, so the plaintext rides along on the test
    # object for building request headers.
    token.define_singleton_method(:token) { plain }
    token
  end

  def mock_cluster(id: 'cluster1', adapter: 'slurm', title: 'Cluster One', login_host: 'login1.example.edu',
                   hidden: nil)
    metadata = mock('metadata')
    metadata.stubs(:title).returns(title)
    metadata.stubs(:hidden).returns(hidden)

    login = mock('login')
    login.stubs(:host).returns(login_host)

    cluster = mock("cluster_#{id}")
    cluster.stubs(:id).returns(id.to_sym)
    cluster.stubs(:job_allow?).returns(true)
    cluster.stubs(:metadata).returns(metadata)
    cluster.stubs(:job_config).returns({ adapter: adapter })
    cluster.stubs(:login).returns(login)
    cluster
  end

  def mock_job_info(id:, status: :running, job_name: 'test-job', job_owner: 'testuser', queue_name: 'batch')
    OodCore::Job::Info.new(
      id:         id,
      status:     OodCore::Job::Status.new(state: status),
      job_name:   job_name,
      job_owner:  job_owner,
      queue_name: queue_name
    )
  end
end
