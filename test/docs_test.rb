# frozen_string_literal: true

require 'English'
require_relative 'test_helper'

# Docs drift silently. Nothing fails when a number in the README stops matching
# the code, so it stays wrong until someone notices — we shipped a guide telling
# Keycloak sites to use the `sub` claim that another guide explicitly forbids.
#
# Only claims with a single source of truth in the repo belong here. Anything
# needing a live cluster (OOD versions, scheduler behaviour) cannot be checked
# from CI and is deliberately absent; those are covered by the live-verification
# guidance in CONTRIBUTING.md instead.
class DocsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # Always UTF-8. Ruby otherwise reads in the locale's encoding, and under a
  # LANG-less environment — an OOD container, a CI runner — that is US-ASCII,
  # so every one of these checks errored on the em-dashes in our own prose.
  def read_doc(name)
    read_utf8(File.join(ROOT, name))
  end

  def read_utf8(path)
    File.read(path, encoding: 'UTF-8')
  end

  # Tracked files only. Globbing the working tree also picks up scratch drafts
  # and anything gitignored, so an untracked note in the repo root could fail
  # the suite for a claim that ships nowhere.
  def all_docs
    @all_docs ||= begin
      out = `git -C #{ROOT} ls-files -z -- '*.md' 'docs/*.md'`
      raise 'git ls-files failed' unless $CHILD_STATUS.success?

      out.split("\0").map { |rel| File.join(ROOT, rel) }
    end
  end

  # The README advertises a tool count. mcp_server.rb is the only place the
  # list actually lives.
  def test_documented_mcp_tool_count_matches_the_server
    src = read_utf8(File.join(ROOT, 'app/mcp_server.rb'))
    actual = src[/tools:\s*\[(.*?)\]/m, 1].scan(/\w+Tool/).uniq.size

    # Numerals only, and the number must sit directly before "tools" (or
    # "MCP tools"). Docs state the count as a numeral, which is more scannable
    # than spelling it out and keeps this pattern tight — allowing filler words
    # made it match the "2" in the "### 3.2 Available tools" heading.
    found = 0
    all_docs.each do |path|
      read_utf8(path).scan(/\b(\d+)[ \t]+(?:MCP[ \t]+)?tools\b/i).flatten.each do |claimed|
        found += 1
        assert_equal actual, claimed.to_i,
                     "#{File.basename(path)} claims #{claimed} tools, server registers #{actual}"
      end
    end

    # Without this the test degrades silently: reword the prose ("nineteen
    # tools") and it finds nothing to check while still passing green. Assert
    # that it matched something, so losing coverage is itself a failure.
    refute_equal 0, found, 'no doc states an MCP tool count — did the wording change?'
  end

  # CONTRIBUTING states the coverage floor; test_helper.rb enforces it.
  def test_documented_coverage_floor_matches_the_enforced_one
    helper = read_utf8(File.join(ROOT, 'test/test_helper.rb'))
    enforced = helper[/minimum_coverage\(line:\s*(\d+)\)/, 1].to_i
    claimed = read_doc('CONTRIBUTING.md')[/line-coverage floor \(currently (\d+)%\)/, 1]
    refute_nil claimed, 'CONTRIBUTING no longer states a coverage floor — did the wording change?'
    claimed = claimed.to_i

    assert_equal enforced, claimed,
                 "CONTRIBUTING says #{claimed}%, test_helper enforces #{enforced}%"
  end

  # CONTRIBUTING names the Ruby versions CI runs; ci.yml is the source of truth.
  def test_documented_ruby_matrix_matches_ci
    ci = read_utf8(File.join(ROOT, '.github/workflows/ci.yml'))
    versions = ci[/ruby:\s*\[(.*?)\]/, 1].scan(/[\d.]+/)
    claimed = read_doc('CONTRIBUTING.md')[/Ruby ([\d.]+)[–-]([\d.]+)/, 0]
    refute_nil claimed, 'CONTRIBUTING no longer states a Ruby range — did the wording change?'

    assert_equal versions.first, claimed[/([\d.]+)/, 1],
                 "CONTRIBUTING's lowest Ruby does not match ci.yml (#{versions.join(', ')})"
    assert_equal versions.last, claimed.scan(/[\d.]+/).last,
                 "CONTRIBUTING's highest Ruby does not match ci.yml (#{versions.join(', ')})"
  end

  # The app-token header name appears in prose across several guides. Getting it
  # wrong hands a reader a request that silently 401s.
  def test_documented_token_header_matches_app_auth
    auth = read_utf8(File.join(ROOT, 'lib/app_auth.rb'))
    header = auth[/TOKEN_HEADER\s*=\s*'HTTP_(\w+)'/, 1].tr('_', '-')

    all_docs.each do |path|
      body = read_utf8(path)
      next unless body.match?(/X-OOD-API/i)

      # Header names are case-insensitive on the wire; the docs use
      # X-OOD-API-Token, the constant is HTTP_X_OOD_API_TOKEN.
      assert_match(/#{Regexp.escape(header)}/i, body,
                   "#{File.basename(path)} references an app-token header other than #{header}")
    end
  end

  # The dashboard's token page renders a curl example directly beneath a newly
  # created token, so a wrong header there is the one instruction a user sees at
  # the moment of issuance. It named `Authorization: Bearer`, which Apache owns
  # for the IdP's JWT — the app token would never reach the app, and would land
  # in a header it was not meant for. The markdown check above cannot catch this
  # (it skips any file that never mentions the right header at all).
  def test_dashboard_token_page_documents_the_app_token_header
    auth = read_utf8(File.join(ROOT, 'lib/app_auth.rb'))
    header = auth[/TOKEN_HEADER\s*=\s*'HTTP_(\w+)'/, 1].tr('_', '-')
    view = File.join(ROOT, 'dashboard-plugin/views/api_tokens/index.html.erb')
    body = read_utf8(view)

    assert_match(/#{Regexp.escape(header)}/i, body,
                 "the token page must show #{header}, the header app_auth.rb reads")
    refute_match(/curl[^\n]*Authorization:\s*Bearer/i, body,
                 'the token page must not tell users to send an app token in Authorization')
  end

  # Every documented write example must send the content type the CSRF filter
  # requires. Three curl examples — mkdir, hold, release — omitted it and
  # returned 415 as written, because they are bodyless and the filter exempts
  # only the DELETE *method*. The prose describing that rule drifted at the
  # same time, so the docs were self-consistently wrong.
  def test_documented_write_examples_send_the_required_content_type
    broken = []
    all_docs.each do |path|
      lines = read_utf8(path).lines
      lines.each_with_index do |line, i|
        next unless line.match?(/curl\b/)

        # A curl invocation continues while lines end in a backslash.
        block = [line]
        j = i
        block << lines[j += 1] while lines[j]&.rstrip&.end_with?('\\') && lines[j + 1]
        text = block.join
        next unless text.match?(/-X\s+(POST|PUT|PATCH)\b/)
        next if text.match?(%r{application/json}i)

        broken << "#{File.basename(path)}:#{i + 1}"
      end
    end

    assert_empty broken,
                 "write examples missing Content-Type: application/json (they return 415): #{broken.join(', ')}"
  end

  # Records every connection attempt into the returned array. Prepended rather
  # than stubbed so a call from anywhere in the stack is caught, including from
  # inside a gem.
  def install_outbound_trip_wire
    require 'socket'
    require 'ood_core'
    calls = []

    TCPSocket.singleton_class.prepend(Module.new do
      define_method(:open) do |*a, **k, &b|
        calls << "TCPSocket.open(#{a.first})"
        super(*a, **k, &b)
      end
    end)

    if defined?(Excon::Connection)
      Excon::Connection.prepend(Module.new do
        define_method(:request) do |*a, **k, &b|
          calls << 'Excon::Connection#request'
          super(*a, **k, &b)
        end
      end)
    end

    calls
  end

  # SECURITY.md says the excon advisory is unreachable because this app makes
  # no outbound HTTP request. Excon IS loaded — it arrives with ood_core — so
  # the claim rests entirely on nothing ever opening a connection, which is a
  # property of the code rather than of the dependency tree.
  #
  # Trip-wire on TCPSocket.open and Excon::Connection#request: exercise the
  # surface and assert neither fires. A future handler that calls out breaks
  # this before the claim in SECURITY.md becomes false.
  def test_no_outbound_connections_from_the_request_surface
    calls = install_outbound_trip_wire

    app = OodApi::App.new
    [['GET', '/api/v1/clusters'], ['GET', '/api/v1/context'],
     ['GET', '/api/v1/env'], ['GET', '/api/v1/files?path=/tmp']].each do |method, path|
      env = Rack::MockRequest.env_for(path, method: method)
      begin
        app.call(env)
      rescue StandardError
        # A route may fail without a cluster config; only the trip-wire matters.
        nil
      end
    end

    assert_empty calls,
                 'SECURITY.md claims no outbound HTTP; these connections were attempted: ' \
                 "#{calls.uniq.join(', ')}"
  end

  # Every relative markdown link must resolve. Renaming a doc is the easiest way
  # to leave a dangling pointer behind.
  def test_relative_markdown_links_resolve
    broken = []
    all_docs.each do |path|
      read_utf8(path).scan(/\]\(([^):#]+\.md)(?:#[^)]*)?\)/).flatten.each do |link|
        target = File.expand_path(link, File.dirname(path))
        broken << "#{File.basename(path)} -> #{link}" unless File.exist?(target)
      end
    end

    assert_empty broken, "broken relative links: #{broken.join(', ')}"
  end
end
