# frozen_string_literal: true

require_relative 'mcp_server'

module OodApi
  # The MCP server over a pair of streams, one JSON-RPC message per line, for
  # a program on the same host that starts this app as a child process. That
  # program already runs as the user, so there is no token and no browser to
  # check. The site's tool settings apply as they do to /mcp, and the site
  # switches this on or off with `local`, apart from `mcp`, so it can serve
  # an assistant of its own without serving clients from outside.
  module Stdio
    # A line this long cannot be a request the server would accept, and
    # reading on would let the peer grow one string without limit.
    class LineTooLong < StandardError; end

    class << self
      # Answers requests from input until it closes.
      #
      # @param input [IO] newline-delimited JSON-RPC messages
      # @param output [IO] where each reply is written, one per line
      def serve(input, output)
        Handlers::Audit.context = { transport: 'stdio' }
        while (line = read_line(input))
          reply = answer(line)
          next unless reply

          output.write(reply, "\n")
          output.flush
        end
      rescue LineTooLong
        output.write(error_line(nil, JSONRPC_INVALID_REQUEST, 'Request too large'), "\n")
        output.flush
      end

      # @param line [String] one message
      # @return [String, nil] the reply as JSON, or nil when none is due
      def answer(line)
        return nil if line.strip.empty?

        parsed = OodApi.parse_json(line)
        OodApi.note_mcp_request(parsed)
        # One request to a line, as /mcp takes one to a body. A batch would
        # pass the checks below unexamined.
        return error_line(nil, JSONRPC_INVALID_REQUEST, 'A message must be a single JSON object') if unusable?(parsed)

        refused = refusal(parsed)
        return reply_to(parsed, *refused) if refused

        OodApi.record_disabled_tool_call(parsed)
        server.handle_json(line)
      rescue Interrupt, SystemExit
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        Handlers::Audit.emit_event(op: 'mcp_request_failed', user: nil, source: 'mcp', error: e.class.to_s)
        reply_to(parsed, JSONRPC_INTERNAL_ERROR, "Internal error: #{e.class}")
      end

      private

      # JSON that is not an object. A line that is not JSON at all is left to
      # the server, which answers with a parse error.
      def unusable?(parsed)
        !parsed.nil? && !parsed.is_a?(Hash)
      end

      def read_line(input)
        limit = OodApi.max_request_bytes
        line = input.gets("\n", limit + 1)
        return nil if line.nil?
        raise LineTooLong if line.bytesize > limit && !line.end_with?("\n")

        line.force_encoding(Encoding::UTF_8).scrub
      end

      # Why a message is not passed to the server, as a JSON-RPC code and
      # text, or nil when it is.
      def refusal(parsed)
        return [JSONRPC_INVALID_REQUEST, off_reason] unless Capabilities.local?
        return nil unless parsed
        return [JSONRPC_METHOD_NOT_FOUND, 'Method not found'] if OodApi.unsupported_method?(parsed)

        problem = BODY_CHECKS.find { |check, _| OodApi.send(check, parsed) }&.last
        [JSONRPC_INVALID_PARAMS, "Invalid params: #{problem}"] if problem
      end

      def off_reason
        if Capabilities.problems.any?
          "The tools are off because this site's settings could not be understood"
        else
          'Local programs are not served at this site'
        end
      end

      # A notification carries no id and is never answered, refused or not.
      def reply_to(parsed, code, message)
        return error_line(nil, code, message) unless parsed
        return nil unless parsed.key?('id')

        error_line(parsed['id'], code, message)
      end

      def error_line(id, code, message)
        JSON.generate(jsonrpc: '2.0', id: id, error: { code: code, message: message })
      end

      # The server for the tools that are on right now, rebuilt when the
      # site's settings change the set.
      def server
        names = Capabilities.enabled_tools.to_a.sort
        @server = nil unless @server_tools == names
        @server_tools = names
        @server ||= OodApi.build_mcp_server
      end
    end
  end
end
