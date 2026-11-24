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
    assert_equal 64, plain_token.length
    assert_equal OodApi::ApiToken.digest(plain_token), token.token_digest
    refute_respond_to token, :token
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
    created, plain = OodApi::ApiToken.create(name: 'Test Token')
    found = OodApi::ApiToken.find_by_token(plain)

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
    token, plain = OodApi::ApiToken.create(name: 'Test Token')
    assert_nil token.last_used_at

    OodApi::ApiToken.touch(token)

    updated = OodApi::ApiToken.find_by_token(plain)
    refute_nil updated.last_used_at
  end

  def test_multiple_tokens_management
    _token1, plain1 = OodApi::ApiToken.create(name: 'Token 1')
    token2, plain2 = OodApi::ApiToken.create(name: 'Token 2')
    _token3, plain3 = OodApi::ApiToken.create(name: 'Token 3')

    assert_equal 3, OodApi::ApiToken.all.size

    OodApi::ApiToken.destroy(token2.id)

    assert_equal 2, OodApi::ApiToken.all.size
    assert_nil OodApi::ApiToken.find_by_token(plain2)
    refute_nil OodApi::ApiToken.find_by_token(plain1)
    refute_nil OodApi::ApiToken.find_by_token(plain3)
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
    # Every touch must write for this to exercise the race.
    OodApi::ApiToken.stubs(:recently_touched?).returns(false)
    token, plain = OodApi::ApiToken.create(name: 'Concurrent')

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
    refute_nil OodApi::ApiToken.find_by_token(plain)
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
    # Every touch must write for this to exercise the race.
    OodApi::ApiToken.stubs(:recently_touched?).returns(false)
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
    # Every touch must write for this to exercise the race.
    OodApi::ApiToken.stubs(:recently_touched?).returns(false)
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

  def test_plaintext_token_is_never_written_to_disk
    _token, plain = OodApi::ApiToken.create(name: 'Hashed')

    on_disk = File.read(@test_token_file)
    refute_includes on_disk, plain
    assert_includes on_disk, OodApi::ApiToken.digest(plain)
  end

  # Files written before hashing, or by hand from the old installation guide,
  # carry a plaintext `token`. They must keep working and be hashed on first use.
  def test_legacy_plaintext_entry_authenticates_and_is_hashed_on_first_use
    FileUtils.mkdir_p(@test_token_dir)
    legacy = 'a' * 64
    File.write(@test_token_file, JSON.generate([{ id: 'legacy-1', name: 'Old', token: legacy }]))

    found = OodApi::ApiToken.find_by_token(legacy)
    refute_nil found
    OodApi::ApiToken.touch(found)

    on_disk = File.read(@test_token_file)
    refute_includes on_disk, legacy
    refute_nil OodApi::ApiToken.find_by_token(legacy)
  end

  def test_stored_digest_is_not_itself_a_credential
    token, _plain = OodApi::ApiToken.create(name: 'Digest')

    assert_nil OodApi::ApiToken.find_by_token(token.token_digest)
  end

  def test_touch_skips_the_write_inside_the_interval
    token, _plain = OodApi::ApiToken.create(name: 'Throttled')
    OodApi::ApiToken.touch(token)
    before = File.stat(@test_token_file).ino

    OodApi::ApiToken.touch(token)

    assert_equal before, File.stat(@test_token_file).ino, 'token file was rewritten inside the touch interval'
  end

  # --- expiry ---

  def with_token_settings(max_days: nil, allow_never: nil)
    ENV['OOD_API_TOKEN_MAX_DAYS'] = max_days.to_s if max_days
    ENV['OOD_API_TOKEN_ALLOW_NEVER'] = allow_never.to_s unless allow_never.nil?
    yield
  ensure
    ENV.delete('OOD_API_TOKEN_MAX_DAYS')
    ENV.delete('OOD_API_TOKEN_ALLOW_NEVER')
  end

  def stored_entries
    JSON.parse(File.read(@test_token_file), symbolize_names: true)
  end

  def test_a_new_token_expires_at_the_site_maximum_by_default
    token, = OodApi::ApiToken.create(name: 'Default')

    expires = Time.iso8601(token.expires_at)
    assert_in_delta Time.now + (365 * 86_400), expires, 60
    refute token.expired?
  end

  def test_the_site_can_shorten_the_maximum
    with_token_settings(max_days: 30) do
      token, = OodApi::ApiToken.create(name: 'Short')

      assert_in_delta Time.now + (30 * 86_400), Time.iso8601(token.expires_at), 60
    end
  end

  def test_an_expired_token_is_found_but_reports_expired
    _token, plain = OodApi::ApiToken.create(name: 'Old', expires_at: (Time.now - 60).iso8601)

    found = OodApi::ApiToken.find_by_token(plain)

    assert found.expired?
  end

  def test_an_unreadable_expiry_counts_as_expired
    _token, plain = OodApi::ApiToken.create(name: 'Bad', expires_at: 'next tuesday')

    assert OodApi::ApiToken.find_by_token(plain).expired?
  end

  # A token created before expiry existed keeps working, and gets the site
  # maximum, counted from the first time the store is rewritten.
  def test_a_token_with_no_expiry_recorded_is_given_one_on_first_use
    FileUtils.mkdir_p(@test_token_dir)
    plain = 'c' * 64
    File.write(@test_token_file,
               JSON.generate([{ id: 'old-1', name: 'Old', token_digest: OodApi::ApiToken.digest(plain) }]))

    found = OodApi::ApiToken.find_by_token(plain)
    refute found.expired?
    OodApi::ApiToken.touch(found)

    stamped = stored_entries.first[:expires_at]
    assert_in_delta Time.now + (365 * 86_400), Time.iso8601(stamped), 60
  end

  def test_never_is_kept_only_where_the_site_allows_it
    FileUtils.mkdir_p(@test_token_dir)
    plain = 'd' * 64
    entry = { id: 'never-1', name: 'Never', token_digest: OodApi::ApiToken.digest(plain), expires_at: nil }
    File.write(@test_token_file, JSON.generate([entry]))

    with_token_settings(allow_never: true) do
      OodApi::ApiToken.touch(OodApi::ApiToken.find_by_token(plain))
      assert_nil stored_entries.first[:expires_at]
    end

    OodApi::ApiToken.stubs(:recently_touched?).returns(false)
    OodApi::ApiToken.touch(OodApi::ApiToken.find_by_token(plain))
    refute_nil stored_entries.first[:expires_at], 'a site that does not allow never gives the token an expiry'
  end

  # The store is the user's own file. A date written by hand beyond the site
  # maximum is pulled back to it the first time the token is used.
  def test_an_expiry_beyond_the_site_maximum_is_capped_on_first_use
    _token, plain = OodApi::ApiToken.create(name: 'Far', expires_at: (Time.now + (10 * 365 * 86_400)).iso8601)

    OodApi::ApiToken.touch(OodApi::ApiToken.find_by_token(plain))

    assert_in_delta Time.now + (365 * 86_400), Time.iso8601(stored_entries.first[:expires_at]), 60
  end

  def test_lowering_the_maximum_shortens_existing_tokens
    _token, plain = OodApi::ApiToken.create(name: 'Year')
    OodApi::ApiToken.stubs(:recently_touched?).returns(true)

    with_token_settings(max_days: 30) do
      OodApi::ApiToken.touch(OodApi::ApiToken.find_by_token(plain))
      assert_in_delta Time.now + (30 * 86_400), Time.iso8601(stored_entries.first[:expires_at]), 60
    end
  end

  def test_an_expiry_inside_the_maximum_is_left_alone
    soon = (Time.now + (7 * 86_400)).iso8601
    _token, plain = OodApi::ApiToken.create(name: 'Week', expires_at: soon)
    OodApi::ApiToken.stubs(:recently_touched?).returns(false)

    OodApi::ApiToken.touch(OodApi::ApiToken.find_by_token(plain))

    assert_equal soon, stored_entries.first[:expires_at]
  end

  def test_bad_settings_fall_back_to_the_default_maximum
    with_token_settings(max_days: 'forever') { assert_equal 365, OodApi::TokenPolicy.max_days }
    with_token_settings(max_days: -5) { assert_equal 365, OodApi::TokenPolicy.max_days }
    refute OodApi::TokenPolicy.allow_never?
  end
end
