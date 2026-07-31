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

  # A newline in a caller-supplied value must not split the record — otherwise
  # a caller can forge additional ood_api_audit lines a log parser will trust.
  def test_log_escapes_newlines_to_prevent_forged_records
    evil = "/home/drew/x\nood_api_audit op=FORGED user=root source=rest status=ok"

    Handlers::Audit.log(op: 'read_file', user: 'drew', source: 'rest', path: evil) { :ok }

    out = stderr_output
    assert_equal(1, out.lines.count { |l| l.include?('ood_api_audit') })
    refute_match(/^ood_api_audit op=FORGED/, out)
    assert_includes out, '\\nood_api_audit op=FORGED'
  end

  def test_log_escapes_carriage_returns_and_tabs
    Handlers::Audit.log(op: 'read_file', user: 'drew', source: 'rest', path: "a\rb\tc") { :ok }

    out = stderr_output
    assert_equal(1, out.lines.count { |l| l.include?('ood_api_audit') })
    assert_includes out, 'path="a\\rb\\tc"'
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

  # Logging must never break the operation it observes. A caller-controlled
  # value that is not valid UTF-8 made `gsub` raise ArgumentError from inside
  # the logger, which replaced a clean 404 with a 500, discarded the audit
  # record, and masked the real exception. Linux filenames are arbitrary byte
  # strings, so this is ordinary input rather than an attack.
  def test_invalid_utf8_value_does_not_raise
    bad = (+'/home/jesse/x').force_encoding('UTF-8') << 255.chr('BINARY').force_encoding('UTF-8')

    Handlers::Audit.emit_event(op: 'probe', user: 'drew', source: 'rest', path: bad)
    assert_includes stderr_output, 'ood_api_audit'
    assert_includes stderr_output, 'op=probe'
  end

  # The block's exception must reach the caller UNCHANGED so the route's error
  # handler still maps it; the audit failure must not substitute its own.
  def test_block_error_is_reraised_unchanged_when_a_value_is_invalid_utf8
    bad = (+'bad').force_encoding('UTF-8') << 255.chr('BINARY').force_encoding('UTF-8')

    err = assert_raises(Handlers::NotFoundError) do
      Handlers::Audit.log(op: 'probe', user: 'drew', source: 'rest', path: bad) do
        raise Handlers::NotFoundError, 'Path not found'
      end
    end
    assert_equal 'Path not found', err.message
    assert_includes stderr_output, 'status=error'
  end

  def test_success_path_returns_block_value_when_a_value_is_invalid_utf8
    bad = (+'ok').force_encoding('UTF-8') << 255.chr('BINARY').force_encoding('UTF-8')

    result = Handlers::Audit.log(op: 'probe', user: 'drew', source: 'rest', path: bad) { :the_result }
    assert_equal :the_result, result
  end

  # A value whose #to_s raises, or returns a non-String, must not fail the call.
  def test_value_with_broken_to_s_does_not_raise
    broken = Class.new { def to_s = raise('boom') }.new
    nonstring = Class.new { def to_s = 5 }.new

    Handlers::Audit.emit_event(op: 'probe', user: 'drew', source: 'rest', path: broken, cluster: nonstring)
    assert_includes stderr_output, '<unprintable>'
  end

  # NotImplementedError and LoadError are ScriptError descendants, and api.rb
  # turns them into real HTTP responses — so they must be audited too.
  def test_script_error_is_audited_and_reraised
    assert_raises(NotImplementedError) do
      Handlers::Audit.log(op: 'probe', user: 'drew', source: 'rest') { raise NotImplementedError, 'nope' }
    end
    assert_includes stderr_output, 'op=probe'
    assert_includes stderr_output, 'status=error'
  end

  # U+2028 does not forge a record for byte-oriented readers, but a JS-based
  # log viewer treats it as a line terminator. \x would render it ambiguously
  # as "\x2028", so it must use the \u form.
  def test_unicode_line_separators_are_escaped_unambiguously
    Handlers::Audit.emit_event(op: 'probe', user: 'drew', source: 'rest', path: "a\u2028b")

    assert_includes stderr_output, '\\u2028'
    assert_equal 1, stderr_output.strip.split("\n").size
  end
end
