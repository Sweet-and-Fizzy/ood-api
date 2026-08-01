# frozen_string_literal: true

require_relative 'test_helper'
require 'cgi'

class FilesApiTest < Minitest::Test
  include TestHelpers

  def setup
    setup_token_storage
    @test_dir = File.join(Dir.tmpdir, "ood-api-test-#{Process.pid}")
    FileUtils.mkdir_p(@test_dir)
  end

  def teardown
    teardown_token_storage
    FileUtils.rm_rf(@test_dir)
  end

  # List directory

  def test_get_files_lists_directory
    token = create_test_token
    FileUtils.touch(File.join(@test_dir, 'file1.txt'))
    FileUtils.touch(File.join(@test_dir, 'file2.txt'))

    get '/api/v1/files', { path: @test_dir }, auth_header(token)

    assert last_response.ok?
    assert_equal 2, json_response['data'].size
    names = json_response['data'].map { |f| f['name'] }
    assert_includes names, 'file1.txt'
    assert_includes names, 'file2.txt'
  end

  def test_get_files_returns_file_metadata
    token = create_test_token
    file_path = File.join(@test_dir, 'test.txt')
    File.write(file_path, 'hello world')

    get '/api/v1/files', { path: file_path }, auth_header(token)

    assert last_response.ok?
    data = json_response['data']
    assert_equal 'test.txt', data['name']
    assert_equal false, data['directory']
    assert_equal 11, data['size']
    assert data.key?('mode')
    assert data.key?('mtime')
  end

  def test_get_files_returns_400_without_path
    token = create_test_token

    get '/api/v1/files', {}, auth_header(token)

    assert_equal 400, last_response.status
    assert_equal 'bad_request', json_response['error']
  end

  def test_get_files_returns_404_for_nonexistent
    token = create_test_token
    nonexistent = File.join(@test_dir, 'does-not-exist-12345')

    get '/api/v1/files', { path: nonexistent }, auth_header(token)

    assert_equal 404, last_response.status
  end

  def test_get_files_returns_403_for_forbidden_path
    token = create_test_token

    get '/api/v1/files', { path: '/etc/passwd' }, auth_header(token)

    assert_equal 403, last_response.status
    assert_equal 'forbidden', json_response['error']
  end

  # Read file content

  def test_get_files_content_returns_file
    token = create_test_token
    file_path = File.join(@test_dir, 'content.txt')
    File.write(file_path, 'test content')

    get '/api/v1/files/content', { path: file_path }, auth_header(token)

    assert last_response.ok?
    assert_equal 'test content', last_response.body
  end

  def test_get_files_content_returns_400_for_directory
    token = create_test_token

    get '/api/v1/files/content', { path: @test_dir }, auth_header(token)

    assert_equal 400, last_response.status
  end

  def test_get_files_content_returns_404_for_nonexistent
    token = create_test_token

    get '/api/v1/files/content', { path: '/tmp/nonexistent-file-12345' }, auth_header(token)

    assert_equal 404, last_response.status
  end

  # max_size was unvalidated: a negative reached File.read and raised an
  # unrescued ArgumentError (500), and a non-numeric coerced to 0 via to_i,
  # silently returning an empty body instead of an error.
  def test_get_files_content_rejects_negative_max_size
    token = create_test_token
    file_path = File.join(@test_dir, 'neg.txt')
    File.write(file_path, 'test content')

    get '/api/v1/files/content', { path: file_path, max_size: '-5' }, auth_header(token)

    assert_equal 400, last_response.status
    assert_match(/max_size/, last_response.body)
  end

  def test_get_files_content_rejects_non_numeric_max_size
    token = create_test_token
    file_path = File.join(@test_dir, 'abc.txt')
    File.write(file_path, 'test content')

    get '/api/v1/files/content', { path: file_path, max_size: 'abc' }, auth_header(token)

    assert_equal 400, last_response.status
    assert_match(/max_size/, last_response.body)
  end

  def test_get_files_content_rejects_zero_max_size
    token = create_test_token
    file_path = File.join(@test_dir, 'zero.txt')
    File.write(file_path, 'test content')

    get '/api/v1/files/content', { path: file_path, max_size: '0' }, auth_header(token)

    assert_equal 400, last_response.status
  end

  # An oversized body must be rejected on Content-Length alone, before Sinatra
  # resolves `params`. Without Content-Type a client gets the form-encoded
  # default, and Rack raises QueryLimitError while parsing — surfacing as an
  # unexplained 500 instead of 413.
  def test_put_files_rejects_oversized_body_without_content_type
    token = create_test_token
    oversized = Handlers::Files::MAX_FILE_WRITE + 1

    put '/api/v1/files',
        'x',
        auth_header(token).merge(
          'QUERY_STRING'   => "path=#{File.join(@test_dir, 'big.bin')}",
          'CONTENT_LENGTH' => oversized.to_s
        )

    assert_equal 413, last_response.status
    assert_match(/payload_too_large/, last_response.body)
  end

  def test_put_files_rejects_oversized_body_with_content_type
    token = create_test_token
    oversized = Handlers::Files::MAX_FILE_WRITE + 1

    put '/api/v1/files',
        'x',
        auth_header(token).merge(
          'QUERY_STRING'   => "path=#{File.join(@test_dir, 'big2.bin')}",
          'CONTENT_TYPE'   => 'application/octet-stream',
          'CONTENT_LENGTH' => oversized.to_s
        )

    assert_equal 413, last_response.status
  end

  # The size check must not run ahead of authentication: an unauthenticated
  # caller should learn nothing, not even the configured write limit.
  def test_oversized_body_without_valid_token_returns_401_not_413
    oversized = Handlers::Files::MAX_FILE_WRITE + 1

    put '/api/v1/files',
        'x',
        'HTTP_X_OOD_API_TOKEN' => 'bogus',
        'QUERY_STRING'         => "path=#{File.join(@test_dir, 'nope.bin')}",
        'CONTENT_LENGTH'       => oversized.to_s

    assert_equal 401, last_response.status
    refute_match(/max \d+ bytes/, last_response.body, 'leaked the write limit pre-auth')
  end

  # Create directory

  def test_post_files_creates_directory
    token = create_test_token
    new_dir = File.join(@test_dir, 'new_subdir')

    post '/api/v1/files', { path: new_dir, type: 'directory' }, auth_header(token)

    assert_equal 201, last_response.status
    assert File.directory?(new_dir)
    assert_equal true, json_response['data']['directory']
  end

  def test_post_files_returns_400_for_existing_directory
    token = create_test_token

    post '/api/v1/files', { path: @test_dir, type: 'directory' }, auth_header(token)

    assert_equal 400, last_response.status
  end

  # Touch file

  def test_post_files_touches_file
    token = create_test_token
    new_file = File.join(@test_dir, 'touched.txt')

    post '/api/v1/files', { path: new_file, touch: 'true' }, auth_header(token)

    assert_equal 201, last_response.status
    assert File.exist?(new_file)
    assert_equal false, json_response['data']['directory']
  end

  # Write file

  def test_put_files_writes_content
    token = create_test_token
    file_path = File.join(@test_dir, 'written.txt')

    put "/api/v1/files?path=#{CGI.escape(file_path)}", 'new content', auth_header(token)

    assert last_response.ok?, "Expected OK but got #{last_response.status}: #{last_response.body}"
    assert_equal 'new content', File.read(file_path)
  end

  def test_put_files_overwrites_existing
    token = create_test_token
    file_path = File.join(@test_dir, 'overwrite.txt')
    File.write(file_path, 'old content')

    put "/api/v1/files?path=#{CGI.escape(file_path)}", 'updated', auth_header(token)

    assert last_response.ok?
    assert_equal 'updated', File.read(file_path)
  end

  def test_put_files_creates_parent_directories
    token = create_test_token
    file_path = File.join(@test_dir, 'subdir', 'deep', 'file.txt')

    put "/api/v1/files?path=#{CGI.escape(file_path)}", 'content', auth_header(token)

    assert last_response.ok?
    assert File.exist?(file_path)
  end

  # Delete file

  def test_delete_files_removes_file
    token = create_test_token
    file_path = File.join(@test_dir, 'to_delete.txt')
    FileUtils.touch(file_path)

    delete '/api/v1/files', { path: file_path }, auth_header(token)

    assert last_response.ok?
    refute File.exist?(file_path)
    assert_equal true, json_response['data']['deleted']
  end

  def test_delete_files_removes_empty_directory
    token = create_test_token
    dir_path = File.join(@test_dir, 'empty_dir')
    FileUtils.mkdir(dir_path)

    delete '/api/v1/files', { path: dir_path }, auth_header(token)

    assert last_response.ok?
    refute File.exist?(dir_path)
  end

  def test_delete_files_returns_400_for_nonempty_directory
    token = create_test_token
    dir_path = File.join(@test_dir, 'nonempty_dir')
    FileUtils.mkdir(dir_path)
    FileUtils.touch(File.join(dir_path, 'file.txt'))

    delete '/api/v1/files', { path: dir_path }, auth_header(token)

    assert_equal 400, last_response.status
    assert File.exist?(dir_path)
  end

  def test_delete_files_recursive_removes_nonempty_directory
    token = create_test_token
    dir_path = File.join(@test_dir, 'recursive_dir')
    FileUtils.mkdir(dir_path)
    FileUtils.touch(File.join(dir_path, 'file.txt'))

    delete '/api/v1/files', { path: dir_path, recursive: 'true' }, auth_header(token)

    assert last_response.ok?
    refute File.exist?(dir_path)
  end

  def test_delete_files_returns_404_for_nonexistent
    token = create_test_token

    delete '/api/v1/files', { path: '/tmp/nonexistent-12345' }, auth_header(token)

    assert_equal 404, last_response.status
  end

  # Path security

  def test_tilde_expansion_works
    token = create_test_token
    # Create a file in home directory for testing
    home_file = File.join(Dir.home, '.ood-api-test-file')
    FileUtils.touch(home_file)

    begin
      get '/api/v1/files', { path: '~/.ood-api-test-file' }, auth_header(token)

      assert last_response.ok?
      assert_equal '.ood-api-test-file', json_response['data']['name']
    ensure
      FileUtils.rm_f(home_file)
    end
  end

  def test_path_traversal_blocked
    token = create_test_token

    get '/api/v1/files', { path: '/tmp/../etc/passwd' }, auth_header(token)

    assert_equal 403, last_response.status
  end

  def test_put_outside_allowed_roots_blocked
    token = create_test_token

    put '/api/v1/files?path=/etc/test-file.txt', 'malicious content', auth_header(token)

    assert_equal 403, last_response.status
    assert_equal 'forbidden', json_response['error']
  end

  def test_delete_outside_allowed_roots_blocked
    token = create_test_token

    delete '/api/v1/files', { path: '/etc/passwd' }, auth_header(token)

    assert_equal 403, last_response.status
    assert_equal 'forbidden', json_response['error']
  end

  # Directory listing order

  def test_directory_listing_sorted
    token = create_test_token

    # Create files and directories with various names
    FileUtils.mkdir(File.join(@test_dir, 'zdir'))
    FileUtils.mkdir(File.join(@test_dir, 'adir'))
    FileUtils.touch(File.join(@test_dir, 'zfile.txt'))
    FileUtils.touch(File.join(@test_dir, 'afile.txt'))

    get '/api/v1/files', { path: @test_dir }, auth_header(token)

    assert last_response.ok?
    names = json_response['data'].map { |f| f['name'] }

    # Directories should come first, then files, both sorted by name
    assert_equal ['adir', 'zdir', 'afile.txt', 'zfile.txt'], names
  end

  # docs/api.md tells clients to send Content-Type: application/json on a write.
  # It previously documented application/octet-stream, which the CSRF filter
  # rejects — so a client following the page got a 415 on every write. Assert
  # the documented header works and the old one does not.
  def test_put_files_accepts_the_documented_content_type
    token = create_test_token
    path = File.join(@test_dir, 'documented_ct.txt')

    put '/api/v1/files', 'hello',
        auth_header(token).merge('QUERY_STRING' => "path=#{path}",
                                 'CONTENT_TYPE' => 'application/json')

    assert_equal 200, last_response.status
    assert_equal 'hello', File.read(path)
  end

  # Without an app token — the default deployment — the CSRF filter is what
  # decides, and octet-stream is refused. docs/api.md used to tell clients to
  # send exactly this header, so every write failed for anyone following it.
  def test_put_files_rejects_octet_stream_with_415_when_app_tokens_are_off
    ENV.delete('OOD_API_APP_TOKENS')
    path = File.join(@test_dir, 'octet.txt')

    put '/api/v1/files', 'hello',
        { 'QUERY_STRING' => "path=#{path}", 'CONTENT_TYPE' => 'application/octet-stream' }

    assert_equal 415, last_response.status
    refute File.exist?(path)
  end
end
