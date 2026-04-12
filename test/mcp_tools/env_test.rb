# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/env'

class ListEnvToolTest < Minitest::Test
  def setup
    @saved_allowlist = ENV['OOD_API_ENV_ALLOWLIST']
    ENV.delete('OOD_API_ENV_ALLOWLIST')
    ENV['SLURM_TEST_VAR'] = 'hello'
  end

  def teardown
    if @saved_allowlist
      ENV['OOD_API_ENV_ALLOWLIST'] = @saved_allowlist
    else
      ENV.delete('OOD_API_ENV_ALLOWLIST')
    end
    ENV.delete('SLURM_TEST_VAR')
  end

  def test_lists_env_vars
    result = ListEnvTool.call(server_context: nil)
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, 'SLURM_TEST_VAR=hello'
  end

  def test_filters_by_prefix
    result = ListEnvTool.call(server_context: nil, prefix: 'SLURM_')
    text = result.to_h[:content].first[:text]
    assert_includes text, 'SLURM_TEST_VAR'
  end
end

class GetEnvToolTest < Minitest::Test
  def setup
    @saved_allowlist = ENV['OOD_API_ENV_ALLOWLIST']
    ENV.delete('OOD_API_ENV_ALLOWLIST')
    ENV['SLURM_TEST_VAR'] = 'world'
  end

  def teardown
    if @saved_allowlist
      ENV['OOD_API_ENV_ALLOWLIST'] = @saved_allowlist
    else
      ENV.delete('OOD_API_ENV_ALLOWLIST')
    end
    ENV.delete('SLURM_TEST_VAR')
  end

  def test_gets_env_var
    result = GetEnvTool.call(server_context: nil, name: 'SLURM_TEST_VAR')
    content = result.to_h
    refute content[:isError]
    assert_equal 'SLURM_TEST_VAR=world', content[:content].first[:text]
  end

  def test_error_on_forbidden_var
    result = GetEnvTool.call(server_context: nil, name: 'SECRET_THING')
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'Access denied'
  end

  def test_error_on_missing_var
    result = GetEnvTool.call(server_context: nil, name: 'SLURM_NONEXISTENT')
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'not found'
  end
end
