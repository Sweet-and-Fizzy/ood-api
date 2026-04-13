# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/audit'

class HandlersAuditTest < Minitest::Test
  def setup
    @original_stderr = $stderr
    $stderr = StringIO.new
  end

  def teardown
    $stderr = @original_stderr
  end

  def stderr_output
    $stderr.string
  end

  def test_log_emits_on_success
    result = Handlers::Audit.log(op: 'test_op', user: 'drew', source: 'rest') { 42 }

    assert_equal 42, result
    assert_includes stderr_output, 'ood_api_audit'
    assert_includes stderr_output, 'op=test_op'
    assert_includes stderr_output, 'user=drew'
    assert_includes stderr_output, 'source=rest'
    assert_includes stderr_output, 'status=ok'
    assert_match(/duration=\d+\.\d+/, stderr_output)
  end

  def test_log_emits_on_error_and_reraises
    assert_raises(Handlers::NotFoundError) do
      Handlers::Audit.log(op: 'fail_op', user: 'drew', source: 'mcp') do
        raise Handlers::NotFoundError, 'Cluster not found'
      end
    end

    assert_includes stderr_output, 'op=fail_op'
    assert_includes stderr_output, 'status=error'
    assert_includes stderr_output, 'error="Cluster not found"'
  end

  def test_log_includes_extra_fields
    Handlers::Audit.log(op: 'submit_job', user: 'drew', source: 'rest', cluster: 'cluster1') { true }

    assert_includes stderr_output, 'cluster=cluster1'
  end

  def test_log_omits_nil_fields
    Handlers::Audit.log(op: 'list_env', user: 'drew', source: 'rest', cluster: nil) { true }

    refute_includes stderr_output, 'cluster='
  end

  def test_log_quotes_values_with_spaces
    assert_raises(Handlers::ForbiddenError) do
      Handlers::Audit.log(op: 'read_file', user: 'drew', source: 'rest') do
        raise Handlers::ForbiddenError, 'Permission denied for path'
      end
    end

    assert_includes stderr_output, 'error="Permission denied for path"'
  end

  def test_log_measures_duration
    Handlers::Audit.log(op: 'slow_op', user: 'drew', source: 'rest') { true }

    duration_match = stderr_output.match(/duration=(\d+\.\d+)/)
    refute_nil duration_match
    assert duration_match[1].to_f >= 0
  end

  def test_log_one_line_per_call
    Handlers::Audit.log(op: 'op1', user: 'drew', source: 'rest') { true }
    Handlers::Audit.log(op: 'op2', user: 'drew', source: 'mcp') { true }

    lines = stderr_output.strip.split("\n")
    assert_equal 2, lines.size
    assert_includes lines[0], 'op=op1'
    assert_includes lines[1], 'op=op2'
  end

  def test_emit_event_logs_without_block
    Handlers::Audit.emit_event(op: 'mcp_initialize', user: 'drew', client: 'claude-code')

    assert_includes stderr_output, 'ood_api_audit'
    assert_includes stderr_output, 'op=mcp_initialize'
    assert_includes stderr_output, 'client=claude-code'
  end
end
