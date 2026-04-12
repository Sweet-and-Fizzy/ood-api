# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/env'

class HandlersEnvTest < Minitest::Test
  def setup
    @saved_env = {}
    # Save and set test env vars
    %w[OOD_API_ENV_ALLOWLIST].each do |key|
      @saved_env[key] = ENV[key]
    end
    ENV.delete('OOD_API_ENV_ALLOWLIST')

    # Set known test variables
    ENV['SLURM_JOB_ID'] = '12345'
    ENV['SLURM_CLUSTER'] = 'cluster1'
    ENV['PBS_JOBID'] = '99999'
    ENV['HOME'] ||= '/home/testuser'
    ENV['SECRET_PASSWORD'] = 'hunter2'
  end

  def teardown
    @saved_env.each do |key, val|
      if val.nil?
        ENV.delete(key)
      else
        ENV[key] = val
      end
    end
    ENV.delete('SLURM_JOB_ID')
    ENV.delete('SLURM_CLUSTER')
    ENV.delete('PBS_JOBID')
    ENV.delete('SECRET_PASSWORD')
  end

  # --- list ---

  def test_list_returns_allowed_vars
    result = Handlers::Env.list
    assert result.key?('SLURM_JOB_ID')
    assert result.key?('HOME')
  end

  def test_list_excludes_disallowed_vars
    result = Handlers::Env.list
    refute result.key?('SECRET_PASSWORD')
  end

  def test_list_filters_by_prefix
    result = Handlers::Env.list(prefix: 'SLURM_')
    assert result.key?('SLURM_JOB_ID')
    assert result.key?('SLURM_CLUSTER')
    refute result.key?('PBS_JOBID')
    refute result.key?('HOME')
  end

  def test_list_returns_sorted_keys
    result = Handlers::Env.list
    keys = result.keys
    assert_equal keys.sort, keys
  end

  # --- get ---

  def test_get_returns_value
    result = Handlers::Env.get(name: 'SLURM_JOB_ID')
    assert_equal({ name: 'SLURM_JOB_ID', value: '12345' }, result)
  end

  def test_get_raises_forbidden_for_blocked_var
    assert_raises(Handlers::ForbiddenError) do
      Handlers::Env.get(name: 'SECRET_PASSWORD')
    end
  end

  def test_get_raises_not_found_for_unset_var
    ENV.delete('SLURM_NONEXISTENT_VAR')
    assert_raises(Handlers::NotFoundError) do
      Handlers::Env.get(name: 'SLURM_NONEXISTENT_VAR')
    end
  end

  def test_get_returns_empty_string_value
    ENV['SLURM_EMPTY_VAR'] = ''
    result = Handlers::Env.get(name: 'SLURM_EMPTY_VAR')
    assert_equal({ name: 'SLURM_EMPTY_VAR', value: '' }, result)
  ensure
    ENV.delete('SLURM_EMPTY_VAR')
  end

  # --- custom allowlist ---

  def test_custom_allowlist_replaces_defaults
    ENV['OOD_API_ENV_ALLOWLIST'] = 'SECRET_PASSWORD,CUSTOM_*'
    ENV['CUSTOM_VAR'] = 'hello'

    result = Handlers::Env.list
    assert result.key?('SECRET_PASSWORD')
    assert result.key?('CUSTOM_VAR')
    refute result.key?('SLURM_JOB_ID'), 'Default prefix SLURM_ should not be included with custom allowlist'
    refute result.key?('HOME'), 'Default exact match HOME should not be included with custom allowlist'
  ensure
    ENV.delete('CUSTOM_VAR')
  end
end
