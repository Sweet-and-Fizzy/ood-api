# frozen_string_literal: true

require_relative 'errors'

module Handlers
  module Audit
    def self.log(op:, user:, source:, **fields)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(4)
      emit(op: op, user: user, source: source, status: 'ok', duration: duration, **fields)
      result
    # ScriptError as well as StandardError: NotImplementedError and LoadError
    # are ScriptError descendants, and api.rb turns them into real HTTP
    # responses, so rescuing only StandardError meant those requests were
    # served but never recorded. The exception is always re-raised — this
    # observes, it does not handle.
    rescue StandardError, ScriptError => e
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(4)
      emit(op: op, user: user, source: source, status: 'error', duration: duration, error: e.message, **fields)
      raise
    end

    def self.emit_event(**fields)
      emit(**fields)
    end

    # Backstop. `quote` is written not to raise, but this is on every request
    # path and a logging failure must never become the caller's failure.
    # Exception rather than StandardError so nothing at all escapes, with an
    # unconditional re-raise for Interrupt/SystemExit, which must not be
    # swallowed.
    def self.emit(**fields)
      parts = fields.filter_map do |k, v|
        next if v.nil?

        "#{k}=#{quote(v)}"
      end
      warn "ood_api_audit #{parts.join(' ')}"
    rescue Interrupt, SystemExit
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      warn "ood_api_audit op=audit_emit_failed status=error error=#{e.class}"
      nil
    end
    private_class_method :emit

    # Audit records are one line each, so any newline in a caller-supplied
    # value (a file path, a job name) would split the record and let the
    # caller forge additional `ood_api_audit` lines. Escape control
    # characters rather than emitting them raw.
    ESCAPES = { '\\' => '\\\\', '"' => '\\"', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t' }.freeze

    # Every C0 control character plus DEL, and the Unicode line separators.
    # Newline and carriage return would split the record and let a caller forge
    # audit lines; the rest are escaped because a raw ESC reaching a terminal is
    # an ANSI-injection vector for anyone tailing the log.
    #
    # U+0085 (NEL) and U+2028/U+2029 do NOT forge a record for byte-oriented
    # consumers -- grep and journald split on \n, and these stay inside the
    # quoted value -- but a JavaScript-based log viewer treats U+2028/U+2029 as
    # line terminators, so escape them rather than assume every downstream
    # reader is byte-oriented.
    UNSAFE = /[\\"\u0000-\u001F\u007F\u0085\u2028\u2029]/

    # Never raises. Logging must not break the operation it observes, and every
    # value here is caller-controlled: a path, a job name, a cluster id.
    #
    # Linux filenames are arbitrary byte strings, so an invalid UTF-8 sequence
    # is ordinary input rather than an attack, and JSON can carry a lone
    # surrogate that survives parsing. Either one made `gsub` raise
    # ArgumentError from inside the logger, which then replaced a clean 4xx
    # with a 500, discarded the audit record entirely, and masked the real
    # exception. `scrub` replaces the bad bytes so the record still names the
    # path that was touched.
    def self.quote(value)
      raw = safe_to_s(value)
      escaped = raw.gsub(UNSAFE) do |c|
        # \x is only unambiguous for single-byte values; U+2028 would render as
        # "\x2028", which reads as \x20 followed by "28". Use \u above U+00FF.
        ESCAPES[c] || (c.ord > 0xFF ? format('\\u%04X', c.ord) : format('\\x%02X', c.ord))
      end
      # Quote on the ORIGINAL value: escaping removes the literal whitespace
      # that would otherwise trigger quoting, and an unquoted value containing
      # backslash escapes is ambiguous to a parser.
      raw.match?(/[\s"=\\]/) || raw != escaped ? "\"#{escaped}\"" : escaped
    end
    private_class_method :quote

    # A value's own #to_s can raise, or return something that is not a String.
    # Neither is worth failing a request over.
    def self.safe_to_s(value)
      raw = value.to_s
      return '<unprintable>' unless raw.is_a?(String)

      raw.valid_encoding? ? raw : raw.scrub('?')
    rescue StandardError
      '<unprintable>'
    end
    private_class_method :safe_to_s
  end
end
