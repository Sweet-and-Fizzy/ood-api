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
end
