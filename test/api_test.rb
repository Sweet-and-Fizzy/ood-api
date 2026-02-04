# frozen_string_literal: true

require_relative 'test_helper'

class ApiTest < Minitest::Test
  include TestHelpers

  def setup
    setup_token_storage
    @mock_clusters = [mock_cluster(id: 'owens'), mock_cluster(id: 'pitzer', title: 'Pitzer Cluster')]
    OodApi::App.stubs(:clusters).returns(@mock_clusters)
  end

  def teardown
    teardown_token_storage
  end

  # Health endpoint

  def test_health_endpoint_returns_ok
    get '/health'

    assert last_response.ok?
    assert_equal({ 'status' => 'ok' }, json_response)
  end

  def test_health_endpoint_does_not_require_auth
    get '/health'

    assert last_response.ok?
  end

  # Authentication

  def test_request_without_auth_returns_401
    get '/api/v1/clusters'

    assert_equal 401, last_response.status
    assert_equal 'unauthorized', json_response['error']
  end

  def test_request_with_invalid_token_returns_401
    get '/api/v1/clusters', {}, { 'HTTP_AUTHORIZATION' => 'Bearer invalid-token' }

    assert_equal 401, last_response.status
    assert_equal 'unauthorized', json_response['error']
  end

  def test_request_with_malformed_auth_header_returns_401
    token = create_test_token
    get '/api/v1/clusters', {}, { 'HTTP_AUTHORIZATION' => "Basic #{token.token}" }

    assert_equal 401, last_response.status
  end

  def test_valid_token_updates_last_used_at
    token = create_test_token
    assert_nil token.last_used_at

    get '/api/v1/clusters', {}, auth_header(token)

    assert last_response.ok?
    updated = OodApi::ApiToken.find_by_token(token.token)
    refute_nil updated.last_used_at
  end

  # Clusters API

  def test_get_clusters_returns_list
    token = create_test_token

    get '/api/v1/clusters', {}, auth_header(token)

    assert last_response.ok?
    assert json_response.key?('data')
    assert_kind_of Array, json_response['data']
    assert_equal 2, json_response['data'].size
  end

  def test_get_clusters_returns_cluster_details
    token = create_test_token

    get '/api/v1/clusters', {}, auth_header(token)

    owens = json_response['data'].find { |c| c['id'] == 'owens' }
    refute_nil owens
    assert_equal 'slurm', owens['adapter']
    assert_equal 'Test Cluster', owens['title']
  end

  def test_get_cluster_returns_details
    token = create_test_token

    get '/api/v1/clusters/owens', {}, auth_header(token)

    assert last_response.ok?
    assert_equal 'owens', json_response['data']['id']
    assert_equal 'slurm', json_response['data']['adapter']
  end

  def test_get_cluster_returns_404_for_unknown
    token = create_test_token

    get '/api/v1/clusters/nonexistent', {}, auth_header(token)

    assert_equal 404, last_response.status
    assert_equal 'not_found', json_response['error']
  end

  # Jobs API - List

  def test_get_jobs_requires_cluster_parameter
    token = create_test_token

    get '/api/v1/jobs', {}, auth_header(token)

    assert_equal 400, last_response.status
    assert_equal 'bad_request', json_response['error']
    assert_match(/cluster/, json_response['message'].downcase)
  end

  def test_get_jobs_returns_400_for_empty_cluster
    token = create_test_token

    get '/api/v1/jobs', { cluster: '' }, auth_header(token)

    assert_equal 400, last_response.status
    assert_equal 'bad_request', json_response['error']
  end

  def test_get_jobs_returns_404_for_unknown_cluster
    token = create_test_token

    get '/api/v1/jobs', { cluster: 'unknown' }, auth_header(token)

    assert_equal 404, last_response.status
  end

  def test_get_jobs_returns_job_list
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info_where_owner).returns([
                                                    mock_job_info(id: '12345', job_name: 'test-job')
                                                  ])

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs', { cluster: 'owens' }, auth_header(token)

    assert last_response.ok?
    assert_equal 1, json_response['data'].size
    assert_equal '12345', json_response['data'].first['job_id']
  end

  # Jobs API - Get

  def test_get_job_returns_details
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info).with('12345').returns(
      mock_job_info(id: '12345', job_name: 'my-job', queue_name: 'batch')
    )

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs/12345', { cluster: 'owens' }, auth_header(token)

    assert last_response.ok?
    assert_equal '12345', json_response['data']['job_id']
    assert_equal 'my-job', json_response['data']['job_name']
  end

  def test_get_job_returns_404_for_unknown_job
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info).with('99999').returns(
      OodCore::Job::Info.new(id: nil, status: OodCore::Job::Status.new(state: :undetermined))
    )

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs/99999', { cluster: 'owens' }, auth_header(token)

    assert_equal 404, last_response.status
  end

  # Jobs API - Submit

  def test_post_jobs_submits_job
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.expects(:submit).returns('12346')
    mock_adapter.stubs(:info).with('12346').returns(
      mock_job_info(id: '12346', status: :queued, job_name: 'api-job')
    )

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    post '/api/v1/jobs',
         { cluster: 'owens', script: { content: "#!/bin/bash\necho hello" }, options: { job_name: 'api-job' } }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 201, last_response.status
    assert_equal '12346', json_response['data']['job_id']
  end

  def test_post_jobs_returns_400_for_missing_cluster
    token = create_test_token

    post '/api/v1/jobs',
         { script: { content: "#!/bin/bash\necho hello" } }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 400, last_response.status
    assert_equal 'bad_request', json_response['error']
  end

  def test_post_jobs_returns_400_for_empty_cluster
    token = create_test_token

    post '/api/v1/jobs',
         { cluster: '', script: { content: "#!/bin/bash\necho hello" } }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 400, last_response.status
    assert_equal 'bad_request', json_response['error']
  end

  def test_post_jobs_returns_400_for_missing_script
    token = create_test_token

    post '/api/v1/jobs',
         { cluster: 'owens' }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 400, last_response.status
  end

  def test_post_jobs_returns_400_for_empty_script
    token = create_test_token

    post '/api/v1/jobs',
         { cluster: 'owens', script: { content: '' } }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 400, last_response.status
  end

  def test_post_jobs_returns_400_for_invalid_json
    token = create_test_token

    post '/api/v1/jobs',
         'not valid json',
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 400, last_response.status
  end

  def test_post_jobs_returns_422_for_submission_failure
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:submit).raises(OodCore::JobAdapterError, 'Invalid script')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    post '/api/v1/jobs',
         { cluster: 'owens', script: { content: 'bad script' } }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 422, last_response.status
    assert_equal 'unprocessable_entity', json_response['error']
  end

  # Jobs API - Delete

  def test_delete_job_cancels_job
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.expects(:delete).with('12345')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    delete '/api/v1/jobs/12345', { cluster: 'owens' }, auth_header(token)

    assert last_response.ok?
    assert_equal '12345', json_response['data']['job_id']
    assert_equal 'cancelled', json_response['data']['status']
  end

  def test_delete_job_returns_400_for_missing_cluster
    token = create_test_token

    delete '/api/v1/jobs/12345', {}, auth_header(token)

    assert_equal 400, last_response.status
  end

  def test_delete_job_returns_422_for_cancellation_failure
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:delete).raises(OodCore::JobAdapterError, 'Permission denied')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    delete '/api/v1/jobs/12345', { cluster: 'owens' }, auth_header(token)

    assert_equal 422, last_response.status
    assert_equal 'unprocessable_entity', json_response['error']
  end

  # Error handling

  def test_scheduler_error_returns_503
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info_where_owner).raises(OodCore::JobAdapterError, 'Connection refused')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs', { cluster: 'owens' }, auth_header(token)

    assert_equal 503, last_response.status
    assert_equal 'service_unavailable', json_response['error']
  end
end
