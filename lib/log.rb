# frozen_string_literal: true

require 'time'

module OodApi
  # Lines this app writes to the PUN log outside a request. They start the
  # way audit records do, so one rule in a log shipper selects them all.
  module Log
    def self.line(text)
      warn "ood_api_audit ts=#{Time.now.utc.iso8601(3)} #{text}"
    end
  end
end
