# frozen_string_literal: true

require_relative 'test_helper'

class ApiTokenTest < Minitest::Test
  include TestHelpers

  def setup
    setup_token_storage
  end

  def teardown
    teardown_token_storage
  end

  def test_all_returns_empty_array_when_no_file
    assert_equal [], OodApi::ApiToken.all
  end

  def test_all_returns_empty_array_when_file_is_empty
    FileUtils.mkdir_p(@test_token_dir)
    File.write(@test_token_file, '[]')

    assert_equal [], OodApi::ApiToken.all
  end

  # Only JSON::ParserError was rescued, so a file that parses but is not an
  # array of objects reached callers that index each entry and raised —
  # turning every authenticated request into a 500. docs/installation.md tells
  # operators they may write this file by hand, so the wrong shape is a
  # realistic mistake rather than a corrupt-disk case.
  def test_malformed_but_parseable_token_files_are_ignored
    FileUtils.mkdir_p(@test_token_dir)

    ['{"id":"a","token":"b"}', '"hello"', 'null', '42', '[1,2,3]', '[null]',
     '[{"id":"a"},"str"]'].each do |body|
      File.write(@test_token_file, body)
      assert_equal [], OodApi::ApiToken.all, "#{body} must be ignored, not raise"
      assert_nil OodApi::ApiToken.find_by_token('anything'), "#{body} must not authenticate"
    end
  end

  def test_create_generates_token_with_valid_attributes
    token, plain_token = OodApi::ApiToken.create(name: 'Test Token')

    assert_kind_of OodApi::ApiToken, token
    refute_nil token.id
    assert_equal 'Test Token', token.name
    refute_nil token.token
    assert_equal 64, token.token.length
    assert_equal plain_token, token.token
    refute_nil token.created_at
  end

  def test_create_persists_token_to_file
    OodApi::ApiToken.create(name: 'Test Token')

    tokens = OodApi::ApiToken.all
    assert_equal 1, tokens.size
    assert_equal 'Test Token', tokens.first.name
  end

  def test_create_sets_secure_permissions
    OodApi::ApiToken.create(name: 'Test Token')

    file_mode = File.stat(@test_token_file).mode & 0o777
    assert_equal 0o600, file_mode
  end

  def test_find_by_token_returns_matching_token
    created, _plain = OodApi::ApiToken.create(name: 'Test Token')
    found = OodApi::ApiToken.find_by_token(created.token)

    refute_nil found
    assert_equal created.id, found.id
    assert_equal created.name, found.name
  end

  def test_find_by_token_returns_nil_for_invalid_token
    OodApi::ApiToken.create(name: 'Test Token')

    assert_nil OodApi::ApiToken.find_by_token('invalid-token')
  end

  def test_find_by_token_returns_nil_for_blank_token
    OodApi::ApiToken.create(name: 'Test Token')

    assert_nil OodApi::ApiToken.find_by_token('')
    assert_nil OodApi::ApiToken.find_by_token(nil)
  end

  def test_destroy_removes_token
    token, _plain = OodApi::ApiToken.create(name: 'Test Token')
    assert_equal 1, OodApi::ApiToken.all.size

    OodApi::ApiToken.destroy(token.id)

    assert_equal 0, OodApi::ApiToken.all.size
  end

  def test_touch_updates_last_used_at
    token, _plain = OodApi::ApiToken.create(name: 'Test Token')
    assert_nil token.last_used_at

    OodApi::ApiToken.touch(token)

    updated = OodApi::ApiToken.find_by_token(token.token)
    refute_nil updated.last_used_at
  end

  def test_multiple_tokens_management
    token1, = OodApi::ApiToken.create(name: 'Token 1')
    token2, = OodApi::ApiToken.create(name: 'Token 2')
    token3, = OodApi::ApiToken.create(name: 'Token 3')

    assert_equal 3, OodApi::ApiToken.all.size

    OodApi::ApiToken.destroy(token2.id)

    assert_equal 2, OodApi::ApiToken.all.size
    assert_nil OodApi::ApiToken.find_by_token(token2.token)
    refute_nil OodApi::ApiToken.find_by_token(token1.token)
    refute_nil OodApi::ApiToken.find_by_token(token3.token)
  end

  def test_handles_malformed_json_gracefully
    FileUtils.mkdir_p(@test_token_dir)
    File.write(@test_token_file, 'not valid json')

    assert_equal [], OodApi::ApiToken.all
  end

  # save_tokens used to open the real file with O_TRUNC and write in place, so
  # a concurrent reader could observe an empty or partial file. load_tokens
  # rescues JSON::ParserError to [], which would silently invalidate every
  # token. Writes now go to a temp file and rename(2) into place.
  def test_concurrent_reads_never_observe_a_partial_file
    token, = OodApi::ApiToken.create(name: 'Concurrent')

    writers = 4.times.map do
      Thread.new { 40.times { OodApi::ApiToken.touch(token) } }
    end
    corrupt = 0
    readers = 4.times.map do
      Thread.new do
        120.times { corrupt += 1 if OodApi::ApiToken.all.empty? }
      end
    end
    (writers + readers).each(&:join)

    assert_equal 0, corrupt, 'a reader observed an empty/torn token file'
    refute_nil OodApi::ApiToken.find_by_token(token.token)
  end

  def test_save_leaves_no_temp_files_behind
    token, = OodApi::ApiToken.create(name: 'Temp')
    OodApi::ApiToken.touch(token)

    # The lock file is intentionally persistent, so exclude it here.
    leftovers = Dir.glob(File.join(@test_token_dir, '.tokens.json.*')) -
                [OodApi::ApiToken::LOCK_FILE]
    assert_empty leftovers, "temp files not cleaned up: #{leftovers.inspect}"
  end

  # touch is bookkeeping on an already-authenticated request; an unwritable
  # store must not turn that request into a 500.
  def test_touch_does_not_raise_when_store_is_unwritable
    token, = OodApi::ApiToken.create(name: 'ReadOnly')
    File.chmod(0o500, @test_token_dir)

    begin
      OodApi::ApiToken.touch(token) # must not raise
    ensure
      File.chmod(0o700, @test_token_dir)
    end
  end

  # The Dashboard plugin writes this same file from a separate process, so
  # these two tests fork rather than thread: in-process threads would never
  # exercise flock(2), which is what actually provides the exclusion.

  # A revoke racing the per-request touch used to be a lost update — both
  # sides load the whole array and write their own copy back, so the revoked
  # token came back and kept authenticating while the UI reported success.
  def test_revoked_token_stays_revoked_under_concurrent_touch
    victim, plain = OodApi::ApiToken.create(name: 'victim')
    others = 5.times.map { |i| OodApi::ApiToken.create(name: "other#{i}").first }

    pids = 3.times.map do
      fork do
        40.times { OodApi::ApiToken.touch(others.sample) }
        exit!(0)
      end
    end
    OodApi::ApiToken.destroy(victim.id)
    pids.each { |pid| Process.waitpid(pid) }

    assert_nil OodApi::ApiToken.find_by_token(plain),
               'revoked token was resurrected by a concurrent touch and still authenticates'
  end

  # A torn read does not raise, it parses as [] — which reads as "no tokens",
  # 401s the user, and then gets written back, destroying the store.
  def test_concurrent_touch_never_yields_a_torn_read
    tokens = 20.times.map { |i| OodApi::ApiToken.create(name: "tok#{i}") }
    all = tokens.map(&:first)
    plain = tokens.first.last

    writers = 2.times.map do
      fork do
        150.times { OodApi::ApiToken.touch(all.sample) }
        exit!(0)
      end
    end

    misses = 0
    300.times { misses += 1 if OodApi::ApiToken.find_by_token(plain).nil? }
    writers.each { |pid| Process.waitpid(pid) }

    assert_equal 0, misses, 'a valid token failed to resolve, indicating a torn read'
    assert_equal 20, OodApi::ApiToken.all.size, 'tokens were lost'
  end
end
