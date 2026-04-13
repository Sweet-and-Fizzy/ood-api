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
    rescue StandardError => e
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(4)
      emit(op: op, user: user, source: source, status: 'error', duration: duration, error: e.message, **fields)
      raise
    end

    def self.emit_event(**fields)
      emit(**fields)
    end

    def self.emit(**fields)
      parts = fields.filter_map do |k, v|
        next if v.nil?

        "#{k}=#{quote(v)}"
      end
      $stderr.puts "ood_api_audit #{parts.join(' ')}"
    end
    private_class_method :emit

    def self.quote(value)
      s = value.to_s
      s.match?(/[\s"=]/) ? "\"#{s.gsub('"', '\\"')}\"" : s
    end
    private_class_method :quote
  end
end
