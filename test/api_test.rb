# frozen_string_literal: true

require_relative 'test_helper'

class ApiTest < Minitest::Test
  include TestHelpers

  def setup
    setup_token_storage
    @mock_clusters = [mock_cluster(id: 'cluster1'), mock_cluster(id: 'cluster2', title: 'Cluster Two')]
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

  # CORS — the app must not emit cross-origin headers. It is served
  # same-origin under the OOD proxy; a wildcard would expose a logged-in
  # user's session to any website. See docs/api.md and docs/mcp-auth.md.

  def test_no_cors_headers_on_responses
    get '/health'

    assert_nil last_response.headers['Access-Control-Allow-Origin']
    assert_nil last_response.headers['Access-Control-Allow-Methods']
    assert_nil last_response.headers['Access-Control-Allow-Headers']
  end

  def test_options_request_is_not_globally_answered
    options '/api/v1/clusters'

    # With the wildcard OPTIONS handler removed, Sinatra no longer returns a
    # blanket 200 for arbitrary preflight requests.
    refute_equal 200, last_response.status
  end

  # Authentication — default (trust-PUN) mode

  def test_default_mode_request_without_auth_succeeds
    ENV.delete('OOD_API_APP_TOKENS')
    get '/api/v1/clusters'

    assert last_response.ok?
  end

  def test_default_mode_passes_through_apache_validated_jwt
    # Option 1 from docs/api.md: Apache validates the JWT against a JWKS
    # before the request reaches the PUN. ood-api must not try to look the
    # JWT up in tokens.json — it has no way to validate it and the lookup
    # would always miss.
    ENV.delete('OOD_API_APP_TOKENS')
    fake_jwt = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhbGljZSJ9.signature'
    get '/api/v1/clusters', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{fake_jwt}" }

    assert last_response.ok?
  end

  # Authentication — opt-in app-token mode (OOD_API_APP_TOKENS=true)

  def test_app_token_mode_request_without_auth_returns_401
    get '/api/v1/clusters'

    assert_equal 401, last_response.status
  end

  def test_app_token_mode_invalid_token_returns_401
    get '/api/v1/clusters', {}, { 'HTTP_X_OOD_API_TOKEN' => 'invalid-token' }

    assert_equal 401, last_response.status
    assert_equal 'unauthorized', json_response['error']
  end

  # Apache owns Authorization — a token presented there is not an app token,
  # even if its value is valid.
  def test_app_token_mode_token_in_authorization_header_returns_401
    token = create_test_token
    get '/api/v1/clusters', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{token.token}" }

    assert_equal 401, last_response.status
  end

  def test_app_token_mode_empty_token_header_returns_401
    get '/api/v1/clusters', {}, { 'HTTP_X_OOD_API_TOKEN' => '' }

    assert_equal 401, last_response.status
  end

  def test_app_token_mode_valid_token_updates_last_used_at
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

    cluster = json_response['data'].find { |c| c['id'] == 'cluster1' }
    refute_nil cluster
    assert_equal 'slurm', cluster['adapter']
    assert_equal 'Cluster One', cluster['title']
  end

  def test_get_cluster_returns_details
    token = create_test_token

    get '/api/v1/clusters/cluster1', {}, auth_header(token)

    assert last_response.ok?
    assert_equal 'cluster1', json_response['data']['id']
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

    get '/api/v1/jobs', { cluster: 'cluster1' }, auth_header(token)

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

    get '/api/v1/jobs/12345', { cluster: 'cluster1' }, auth_header(token)

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

    get '/api/v1/jobs/99999', { cluster: 'cluster1' }, auth_header(token)

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
         { cluster: 'cluster1', script: { content: "#!/bin/bash\necho hello" },
options: { job_name: 'api-job' } }.to_json,
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
         { cluster: 'cluster1' }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 400, last_response.status
  end

  def test_post_jobs_returns_400_for_empty_script
    token = create_test_token

    post '/api/v1/jobs',
         { cluster: 'cluster1', script: { content: '' } }.to_json,
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

  # Valid JSON of the wrong shape. Every one of these used to 500: the body is
  # indexed like a Hash, so an Array raises TypeError and a scalar NoMethodError.
  def test_post_jobs_returns_400_for_non_object_json_body
    token = create_test_token

    ['[1,2,3]', 'null', '42', '"hello"'].each do |body|
      post '/api/v1/jobs', body, auth_header(token).merge('CONTENT_TYPE' => 'application/json')
      assert_equal 400, last_response.status, "body #{body.inspect} should be a 400"
    end
  end

  def test_post_jobs_returns_400_when_script_or_options_is_not_an_object
    token = create_test_token

    [{ cluster: 'cluster1', script: 'x' },
     { cluster: 'cluster1', script: { content: '#!/bin/bash' }, options: 'x' }].each do |body|
      post '/api/v1/jobs', body.to_json, auth_header(token).merge('CONTENT_TYPE' => 'application/json')
      assert_equal 400, last_response.status, "body #{body.inspect} should be a 400"
    end
  end

  # Rack turns ?p[]=x into an Array and ?p[k]=x into a Hash; the handler then
  # calls start_with? on it and raises TypeError.
  def test_env_prefix_rejects_non_scalar_values
    token = create_test_token

    get '/api/v1/env?prefix[]=OOD', {}, auth_header(token)
    assert_equal 400, last_response.status

    get '/api/v1/env?prefix[a]=OOD', {}, auth_header(token)
    assert_equal 400, last_response.status
  end

  # A NUL reaches File.expand_path and raises ArgumentError — a malformed
  # request, not a server fault.
  def test_file_routes_reject_null_byte_in_path
    token = create_test_token
    path = "/tmp/evil\0.txt"

    get "/api/v1/files?path=#{CGI.escape(path)}", {}, auth_header(token)
    assert_equal 400, last_response.status

    get "/api/v1/files/content?path=#{CGI.escape(path)}", {}, auth_header(token)
    assert_equal 400, last_response.status

    delete "/api/v1/files?path=#{CGI.escape(path)}", {}, auth_header(token)
    assert_equal 400, last_response.status
  end

  def test_post_jobs_returns_422_for_submission_failure
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:submit).raises(OodCore::JobAdapterError, 'Invalid script')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    post '/api/v1/jobs',
         { cluster: 'cluster1', script: { content: 'bad script' } }.to_json,
         auth_header(token).merge('CONTENT_TYPE' => 'application/json')

    assert_equal 422, last_response.status
    assert_equal 'unprocessable_entity', json_response['error']
  end

  # Jobs API - Delete

  def test_delete_job_cancels_job
    token = create_test_token

    mock_adapter = mock('adapter')
    # cancel confirms the job exists first; ood_core reports success for an
    # unknown id, so the API would otherwise fabricate a 'cancelled' status.
    mock_adapter.stubs(:info).with('12345').returns(mock_job_info(id: '12345', job_owner: 'drew'))
    mock_adapter.expects(:delete).with('12345')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    delete '/api/v1/jobs/12345', { cluster: 'cluster1' }, auth_header(token)

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
    mock_adapter.stubs(:info).with('12345').returns(mock_job_info(id: '12345', job_owner: 'drew'))
    mock_adapter.stubs(:delete).raises(OodCore::JobAdapterError, 'Permission denied')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    delete '/api/v1/jobs/12345', { cluster: 'cluster1' }, auth_header(token)

    assert_equal 422, last_response.status
    assert_equal 'unprocessable_entity', json_response['error']
  end

  # Error handling

  def test_scheduler_error_returns_503
    token = create_test_token

    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info_where_owner).raises(OodCore::JobAdapterError, 'Connection refused')

    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs', { cluster: 'cluster1' }, auth_header(token)

    assert_equal 503, last_response.status
    assert_equal 'service_unavailable', json_response['error']
  end

  # Context endpoint

  def test_get_context_returns_data
    token = create_test_token

    get '/api/v1/context', {}, auth_header(token)

    assert last_response.ok?
    assert json_response.key?('data')
    assert json_response['data'].key?('content')
  end

  # The per-route rescue lists had drifted apart — PUT /files 500'd on
  # NotFoundError, POST /files on StorageError, GET /files on ValidationError.
  # These application-wide handlers are the backstop that keeps a route which
  # omits a rescue from returning a blank 500.
  def test_global_handler_maps_storage_error_from_a_route_without_a_rescue
    token = create_test_token
    Handlers::Files.stubs(:touch).raises(Handlers::StorageError, 'No space left on device')

    post '/api/v1/files?path=/tmp/x.txt&touch=1', {}, auth_header(token).merge('CONTENT_TYPE' => 'application/json')
    assert_equal 507, last_response.status
    assert_equal 'insufficient_storage', json_response['error']
  end

  def test_global_handler_maps_not_found_from_a_route_without_a_rescue
    token = create_test_token
    Handlers::Files.stubs(:write).raises(Handlers::NotFoundError, 'File not found')

    put '/api/v1/files?path=/tmp/x.txt', 'body', auth_header(token).merge('CONTENT_TYPE' => 'application/json')
    assert_equal 404, last_response.status
  end

  # LoadError and NotImplementedError descend from ScriptError, so neither a
  # bare rescue nor Sinatra's default handling catches them.
  def test_script_error_is_reported_rather_than_returning_a_blank_500
    token = create_test_token
    Handlers::Clusters.stubs(:list).raises(NotImplementedError, 'adapter missing')

    get '/api/v1/clusters', {}, auth_header(token)
    assert_equal 500, last_response.status
    assert_equal 'internal_error', json_response['error']
  end

  # With OOD's default cookie-based Apache auth, a browser attaches the
  # session cookie to a cross-origin form post automatically — so an attacker
  # page could write, delete, or submit jobs as a logged-in user. An HTML form
  # can only send these three content types; anything else preflights, which
  # our absent CORS headers then fail.
  def test_state_changing_requests_reject_form_content_types
    ENV.delete('OOD_API_APP_TOKENS')
    path = File.join(Dir.tmpdir, "csrf_probe_#{SecureRandom.hex(4)}.txt")
    FileUtils.rm_f(path)

    ['text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data'].each do |ct|
      put "/api/v1/files?path=#{CGI.escape(path)}", 'pwned', { 'CONTENT_TYPE' => ct }
      assert_equal 415, last_response.status, "#{ct} must not be accepted on a write"
    end

    refute File.exist?(path), 'a form-content-type write must not land'
  ensure
    FileUtils.rm_f(path) if path
  end

  def test_state_changing_requests_accept_json
    ENV.delete('OOD_API_APP_TOKENS')
    path = File.join(Dir.tmpdir, "csrf_ok_#{SecureRandom.hex(4)}.txt")

    put "/api/v1/files?path=#{CGI.escape(path)}", 'hello', { 'CONTENT_TYPE' => 'application/json' }
    assert_equal 200, last_response.status
  ensure
    FileUtils.rm_f(path) if path
  end

  # DELETE sends no body and no Content-Type; curl and Rack both fill in a
  # default one, so the guard keys on body length rather than media type.
  def test_bodyless_state_changing_requests_are_allowed
    ENV.delete('OOD_API_APP_TOKENS')
    path = File.join(Dir.tmpdir, "csrf_del_#{SecureRandom.hex(4)}.txt")
    File.write(path, 'x')

    delete "/api/v1/files?path=#{CGI.escape(path)}", {}, {}
    assert_equal 200, last_response.status
    refute File.exist?(path)
  end

  # An app token does not exempt a write from the content-type requirement,
  # even a valid one. The filter cannot tell a valid token from an invented
  # string without running authentication, and with app tokens off there is no
  # authentication to run — so exempting on the header at all would let any
  # value through. Requiring JSON costs a token-bearing client nothing.
  def test_app_token_does_not_exempt_the_content_type_requirement
    token = create_test_token
    path = File.join(Dir.tmpdir, "csrf_tok_#{SecureRandom.hex(4)}.txt")

    put "/api/v1/files?path=#{CGI.escape(path)}", 'hello',
        auth_header(token).merge('CONTENT_TYPE' => 'text/plain')
    assert_equal 415, last_response.status
    refute File.exist?(path)

    put "/api/v1/files?path=#{CGI.escape(path)}", 'hello',
        auth_header(token).merge('CONTENT_TYPE' => 'application/json')
    assert_equal 200, last_response.status
  ensure
    FileUtils.rm_f(path) if path
  end

  # Sinatra merges @request.params before it runs `before` filters, so the body
  # parse happens upstream of authenticate!. A malformed multipart body escaped
  # as Rack's own HTML error naming an internal class, and one with too many
  # parts as a bare 500 — both to a caller who had not authenticated, which is
  # exactly what the filter ordering is documented to prevent.
  def test_malformed_multipart_body_returns_json_without_disclosing_internals
    parts = Array.new(10_000) { |i| "--x\r\nContent-Disposition: form-data; name=\"f#{i}\"\r\n\r\nv\r\n" }
    oversized = "#{parts.join}--x--\r\n"
    [['garbage', 'unparseable'], [oversized, 'too many parts']].each do |body, label|
      post '/api/v1/files?path=/tmp/x', body,
           { 'CONTENT_TYPE' => 'multipart/form-data; boundary=x' }

      assert_equal 400, last_response.status, "#{label} must be a 400"
      assert_includes last_response.headers['content-type'].to_s, 'json',
                      "#{label} must not answer in HTML"
      refute_match(/Rack::|<h1>/, last_response.body,
                   "#{label} must not name an internal class")
    end
  end

  def test_reads_are_unaffected_by_the_content_type_requirement
    ENV.delete('OOD_API_APP_TOKENS')
    get '/api/v1/clusters', {}, { 'CONTENT_TYPE' => 'text/plain' }
    assert last_response.ok?
  end

  # `status` used to carry the raw native state, so a queued Slurm job reported
  # `pending` where the docs promised `queued` — and the polling example in
  # docs/api.md could never match. The native word is still available, because
  # ood_core flattens cancelled/timeout/failed all into `completed`.
  def test_job_status_uses_the_portable_vocabulary_and_exposes_native_state
    token = create_test_token
    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info).with('12345').returns(
      OodCore::Job::Info.new(
        id: '12345', job_owner: 'alice',
        status: OodCore::Job::Status.new(state: :queued),
        native: { state: 'PENDING' }
      )
    )
    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs/12345', { cluster: 'cluster1' }, auth_header(token)

    assert last_response.ok?
    assert_equal 'queued', json_response['data']['status']
    assert_equal 'pending', json_response['data']['native_state']
  end

  def test_native_state_is_null_when_the_adapter_exposes_none
    token = create_test_token
    mock_adapter = mock('adapter')
    mock_adapter.stubs(:info).with('12345').returns(
      OodCore::Job::Info.new(id: '12345', job_owner: 'alice',
                             status: OodCore::Job::Status.new(state: :running))
    )
    @mock_clusters.first.stubs(:job_adapter).returns(mock_adapter)

    get '/api/v1/jobs/12345', { cluster: 'cluster1' }, auth_header(token)

    assert_equal 'running', json_response['data']['status']
    assert_nil json_response['data']['native_state']
  end

  # The first CSRF fix exempted any bodyless request, reasoning that DELETE
  # sends no body. But a form with no fields posts an EMPTY body with a form
  # content type, so cross-origin touch, mkdir, hold and release still worked.
  # The exemption is now scoped to the DELETE method, which no form can issue.
  def test_empty_form_body_cannot_drive_state_changing_posts
    ENV.delete('OOD_API_APP_TOKENS')
    path = File.join(Dir.tmpdir, "empty_form_#{SecureRandom.hex(4)}.txt")

    post "/api/v1/files?path=#{CGI.escape(path)}&touch=1", '',
         { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
    assert_equal 415, last_response.status
    refute File.exist?(path), 'an empty form post must not create a file'

    post '/api/v1/jobs/1/hold?cluster=cluster1', '',
         { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
    assert_equal 415, last_response.status
  ensure
    FileUtils.rm_f(path) if path
  end
end
