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

  def read_doc(name)
    File.read(File.join(ROOT, name))
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
    src = File.read(File.join(ROOT, 'app/mcp_server.rb'))
    actual = src[/tools:\s*\[(.*?)\]/m, 1].scan(/\w+Tool/).uniq.size

    # Numerals only, and the number must sit directly before "tools" (or
    # "MCP tools"). Docs state the count as a numeral, which is more scannable
    # than spelling it out and keeps this pattern tight — allowing filler words
    # made it match the "2" in the "### 3.2 Available tools" heading.
    found = 0
    all_docs.each do |path|
      File.read(path).scan(/\b(\d+)[ \t]+(?:MCP[ \t]+)?tools\b/i).flatten.each do |claimed|
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
    helper = File.read(File.join(ROOT, 'test/test_helper.rb'))
    enforced = helper[/minimum_coverage\(line:\s*(\d+)\)/, 1].to_i
    claimed = read_doc('CONTRIBUTING.md')[/line-coverage floor \(currently (\d+)%\)/, 1]
    refute_nil claimed, 'CONTRIBUTING no longer states a coverage floor — did the wording change?'
    claimed = claimed.to_i

    assert_equal enforced, claimed,
                 "CONTRIBUTING says #{claimed}%, test_helper enforces #{enforced}%"
  end

  # CONTRIBUTING names the Ruby versions CI runs; ci.yml is the source of truth.
  def test_documented_ruby_matrix_matches_ci
    ci = File.read(File.join(ROOT, '.github/workflows/ci.yml'))
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
    auth = File.read(File.join(ROOT, 'lib/app_auth.rb'))
    header = auth[/TOKEN_HEADER\s*=\s*'HTTP_(\w+)'/, 1].tr('_', '-')

    all_docs.each do |path|
      body = File.read(path)
      next unless body.match?(/X-OOD-API/i)

      # Header names are case-insensitive on the wire; the docs use
      # X-OOD-API-Token, the constant is HTTP_X_OOD_API_TOKEN.
      assert_match(/#{Regexp.escape(header)}/i, body,
                   "#{File.basename(path)} references an app-token header other than #{header}")
    end
  end

  # Every relative markdown link must resolve. Renaming a doc is the easiest way
  # to leave a dangling pointer behind.
  def test_relative_markdown_links_resolve
    broken = []
    all_docs.each do |path|
      File.read(path).scan(/\]\(([^):#]+\.md)(?:#[^)]*)?\)/).flatten.each do |link|
        target = File.expand_path(link, File.dirname(path))
        broken << "#{File.basename(path)} -> #{link}" unless File.exist?(target)
      end
    end

    assert_empty broken, "broken relative links: #{broken.join(', ')}"
  end
end
