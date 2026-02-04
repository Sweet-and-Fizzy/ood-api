# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'

require 'minitest/autorun'
require 'rack/test'
require 'mocha/minitest'
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

  def auth_header(token)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token.token}" }
  end

  def json_response
    JSON.parse(last_response.body)
  end

  def setup_token_storage
    @test_token_dir = File.join(Dir.tmpdir, "ood_api_test_#{SecureRandom.hex(4)}")
    @test_token_file = File.join(@test_token_dir, 'tokens.json')

    # Override the constants
    OodApi::ApiToken.send(:remove_const, :TOKENS_DIR) if OodApi::ApiToken.const_defined?(:TOKENS_DIR)
    OodApi::ApiToken.send(:remove_const, :TOKENS_FILE) if OodApi::ApiToken.const_defined?(:TOKENS_FILE)
    OodApi::ApiToken.const_set(:TOKENS_DIR, @test_token_dir)
    OodApi::ApiToken.const_set(:TOKENS_FILE, @test_token_file)
  end

  def teardown_token_storage
    FileUtils.rm_rf(@test_token_dir) if @test_token_dir && File.exist?(@test_token_dir)
  end

  def create_test_token(name = 'Test Token')
    token, _plain = OodApi::ApiToken.create(name: name)
    token
  end

  def mock_cluster(id: 'test', adapter: 'slurm', title: 'Test Cluster', login_host: 'test.example.com')
    metadata = mock('metadata')
    metadata.stubs(:title).returns(title)

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
