# frozen_string_literal: true

require_relative 'test_helper'

class EnvApiTest < Minitest::Test
  include TestHelpers

  def setup
    setup_token_storage
    @mock_clusters = [mock_cluster(id: 'cluster1')]
    OodApi::App.stubs(:clusters).returns(@mock_clusters)
  end

  def teardown
    teardown_token_storage
  end

  # Allowlist parsing

  def test_default_allowlist_includes_prefix_matches
    token = create_test_token

    ENV['SLURM_JOB_ID'] = '12345'
    ENV['PBS_JOBID'] = '67890'
    ENV['LMOD_DIR'] = '/opt/lmod'
    ENV['MODULEPATH'] = '/opt/modules'
    ENV['OOD_TEST_VAR'] = 'test'
    ENV['SGE_ROOT'] = '/opt/sge'
    ENV['LSB_JOBID'] = '111'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_equal '12345', data['SLURM_JOB_ID']
      assert_equal '67890', data['PBS_JOBID']
      assert_equal '/opt/lmod', data['LMOD_DIR']
      assert_equal '/opt/modules', data['MODULEPATH']
      assert_equal 'test', data['OOD_TEST_VAR']
      assert_equal '/opt/sge', data['SGE_ROOT']
      assert_equal '111', data['LSB_JOBID']
    ensure
      ENV.delete('SLURM_JOB_ID')
      ENV.delete('PBS_JOBID')
      ENV.delete('LMOD_DIR')
      ENV.delete('MODULEPATH')
      ENV.delete('OOD_TEST_VAR')
      ENV.delete('SGE_ROOT')
      ENV.delete('LSB_JOBID')
    end
  end

  def test_default_allowlist_includes_exact_matches
    token = create_test_token

    get '/api/v1/env', {}, auth_header(token)

    assert last_response.ok?
    data = json_response['data']
    # HOME and USER should always be set in the test environment
    assert data.key?('HOME')
    assert data.key?('USER')
  end

  def test_default_allowlist_excludes_secrets
    token = create_test_token

    ENV['AWS_SECRET_ACCESS_KEY'] = 'supersecret'
    ENV['DATABASE_PASSWORD'] = 'dbpass'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      refute data.key?('AWS_SECRET_ACCESS_KEY')
      refute data.key?('DATABASE_PASSWORD')
    ensure
      ENV.delete('AWS_SECRET_ACCESS_KEY')
      ENV.delete('DATABASE_PASSWORD')
    end
  end

  def test_custom_allowlist_replaces_defaults
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = 'CUSTOM_*,MY_VAR'
    ENV['CUSTOM_FOO'] = 'bar'
    ENV['MY_VAR'] = 'hello'
    ENV['SLURM_JOB_ID'] = '12345'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_equal 'bar', data['CUSTOM_FOO']
      assert_equal 'hello', data['MY_VAR']
      refute data.key?('SLURM_JOB_ID')
      refute data.key?('HOME')
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
      ENV.delete('CUSTOM_FOO')
      ENV.delete('MY_VAR')
      ENV.delete('SLURM_JOB_ID')
    end
  end

  def test_empty_allowlist_exposes_nothing
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = ''

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_empty data
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
    end
  end

  def test_allowlist_strips_whitespace
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = ' CUSTOM_* , MY_VAR '
    ENV['CUSTOM_FOO'] = 'bar'
    ENV['MY_VAR'] = 'hello'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_equal 'bar', data['CUSTOM_FOO']
      assert_equal 'hello', data['MY_VAR']
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
      ENV.delete('CUSTOM_FOO')
      ENV.delete('MY_VAR')
    end
  end

  def test_allowlist_deduplicates_entries
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = 'MY_VAR,MY_VAR,SLURM_*,SLURM_*'
    ENV['MY_VAR'] = 'hello'
    ENV['SLURM_JOB_ID'] = '123'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_equal 'hello', data['MY_VAR']
      assert_equal '123', data['SLURM_JOB_ID']
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
      ENV.delete('MY_VAR')
      ENV.delete('SLURM_JOB_ID')
    end
  end

  def test_bare_wildcard_does_not_expose_everything
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = '*,MY_VAR'
    ENV['MY_VAR'] = 'hello'
    ENV['SECRET_KEY'] = 'should_not_appear'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_equal 'hello', data['MY_VAR']
      refute data.key?('SECRET_KEY')
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
      ENV.delete('MY_VAR')
      ENV.delete('SECRET_KEY')
    end
  end

  # Prefix filtering

  def test_prefix_filter_narrows_results
    token = create_test_token

    ENV['SLURM_JOB_ID'] = '123'
    ENV['SLURM_CONF'] = '/etc/slurm'
    ENV['PBS_JOBID'] = '456'

    begin
      get '/api/v1/env', { prefix: 'SLURM_' }, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert data.key?('SLURM_JOB_ID')
      assert data.key?('SLURM_CONF')
      refute data.key?('PBS_JOBID')
      refute data.key?('HOME')
    ensure
      ENV.delete('SLURM_JOB_ID')
      ENV.delete('SLURM_CONF')
      ENV.delete('PBS_JOBID')
    end
  end

  def test_prefix_filter_cannot_widen_allowlist
    token = create_test_token

    ENV['AWS_SECRET_ACCESS_KEY'] = 'secret'

    begin
      get '/api/v1/env', { prefix: 'AWS_' }, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      refute data.key?('AWS_SECRET_ACCESS_KEY')
    ensure
      ENV.delete('AWS_SECRET_ACCESS_KEY')
    end
  end

  # Single variable lookup

  def test_get_single_var_returns_value
    token = create_test_token

    get '/api/v1/env/HOME', {}, auth_header(token)

    assert last_response.ok?
    data = json_response['data']
    assert_equal 'HOME', data['name']
    assert_equal ENV['HOME'], data['value']
  end

  def test_get_single_var_returns_403_for_blocked_var
    token = create_test_token

    ENV['AWS_SECRET_ACCESS_KEY'] = 'secret'

    begin
      get '/api/v1/env/AWS_SECRET_ACCESS_KEY', {}, auth_header(token)

      assert_equal 403, last_response.status
      assert_equal 'forbidden', json_response['error']
      assert_match(/allowlist/, json_response['message'])
    ensure
      ENV.delete('AWS_SECRET_ACCESS_KEY')
    end
  end

  def test_get_single_var_returns_404_for_unset_allowed_var
    token = create_test_token

    # SCRATCH is in the default exact allowlist but likely not set in test env
    ENV.delete('SCRATCH')

    get '/api/v1/env/SCRATCH', {}, auth_header(token)

    assert_equal 404, last_response.status
    assert_equal 'not_found', json_response['error']
  end

  def test_get_single_var_returns_empty_string_value
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = 'TEST_EMPTY'
    ENV['TEST_EMPTY'] = ''

    begin
      get '/api/v1/env/TEST_EMPTY', {}, auth_header(token)

      assert last_response.ok?
      data = json_response['data']
      assert_equal 'TEST_EMPTY', data['name']
      assert_equal '', data['value']
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
      ENV.delete('TEST_EMPTY')
    end
  end

  # Sorted output

  def test_bulk_response_is_sorted_alphabetically
    token = create_test_token

    ENV['OOD_API_ENV_ALLOWLIST'] = 'ZZZ_VAR,AAA_VAR,MMM_VAR'
    ENV['ZZZ_VAR'] = 'z'
    ENV['AAA_VAR'] = 'a'
    ENV['MMM_VAR'] = 'm'

    begin
      get '/api/v1/env', {}, auth_header(token)

      assert last_response.ok?
      keys = json_response['data'].keys
      assert_equal %w[AAA_VAR MMM_VAR ZZZ_VAR], keys
    ensure
      ENV.delete('OOD_API_ENV_ALLOWLIST')
      ENV.delete('ZZZ_VAR')
      ENV.delete('AAA_VAR')
      ENV.delete('MMM_VAR')
    end
  end

  # Authentication required

  def test_env_endpoint_requires_auth
    get '/api/v1/env'

    assert_equal 401, last_response.status
  end

  def test_env_single_endpoint_requires_auth
    get '/api/v1/env/HOME'

    assert_equal 401, last_response.status
  end

  # REMOTE_USER authentication (Apache JWT / Option A)

  def test_env_endpoint_works_with_remote_user
    ENV['SLURM_JOB_ID'] = '999'

    begin
      get '/api/v1/env', {}, { 'REMOTE_USER' => 'testuser' }

      assert last_response.ok?
      data = json_response['data']
      assert_equal '999', data['SLURM_JOB_ID']
    ensure
      ENV.delete('SLURM_JOB_ID')
    end
  end

  def test_env_single_endpoint_works_with_remote_user
    get '/api/v1/env/HOME', {}, { 'REMOTE_USER' => 'testuser' }

    assert last_response.ok?
    assert_equal 'HOME', json_response['data']['name']
  end
end
