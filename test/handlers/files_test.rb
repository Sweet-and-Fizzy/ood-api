# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/files'

class HandlersFilesTest < Minitest::Test
  def setup
    @test_dir = File.join(Dir.tmpdir, "ood-handler-test-#{Process.pid}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@test_dir)
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  # list — directory entries

  def test_list_returns_children_for_directory
    FileUtils.touch(File.join(@test_dir, 'a.txt'))
    FileUtils.touch(File.join(@test_dir, 'b.txt'))

    result = Handlers::Files.list(path: @test_dir)

    assert_kind_of Array, result
    names = result.map { |p| p.basename.to_s }
    assert_includes names, 'a.txt'
    assert_includes names, 'b.txt'
  end

  def test_list_returns_pathname_for_single_file
    file_path = File.join(@test_dir, 'single.txt')
    File.write(file_path, 'hello')

    result = Handlers::Files.list(path: file_path)

    assert_kind_of Pathname, result
    assert_equal 'single.txt', result.basename.to_s
  end

  def test_list_raises_not_found_for_missing_path
    assert_raises(Handlers::NotFoundError) do
      Handlers::Files.list(path: File.join(@test_dir, 'nope'))
    end
  end

  def test_list_raises_forbidden_for_disallowed_path
    assert_raises(Handlers::ForbiddenError) do
      Handlers::Files.list(path: '/etc/passwd')
    end
  end

  # read

  def test_read_returns_content
    file_path = File.join(@test_dir, 'read.txt')
    File.write(file_path, 'content here')

    result = Handlers::Files.read(path: file_path)

    assert_equal 'content here', result
  end

  def test_read_raises_not_found
    assert_raises(Handlers::NotFoundError) do
      Handlers::Files.read(path: File.join(@test_dir, 'missing.txt'))
    end
  end

  def test_read_raises_validation_error_for_directory
    assert_raises(Handlers::ValidationError) do
      Handlers::Files.read(path: @test_dir)
    end
  end

  # write

  def test_write_creates_file
    file_path = File.join(@test_dir, 'new.txt')

    result = Handlers::Files.write(path: file_path, content: 'hello')

    assert_kind_of Pathname, result
    assert_equal 'hello', File.read(file_path)
  end

  def test_write_overwrites_existing
    file_path = File.join(@test_dir, 'exist.txt')
    File.write(file_path, 'old')

    Handlers::Files.write(path: file_path, content: 'new')

    assert_equal 'new', File.read(file_path)
  end

  def test_write_creates_parent_directories
    file_path = File.join(@test_dir, 'sub', 'deep', 'file.txt')

    Handlers::Files.write(path: file_path, content: 'deep')

    assert_equal 'deep', File.read(file_path)
  end

  def test_write_raises_validation_error_for_directory
    assert_raises(Handlers::ValidationError) do
      Handlers::Files.write(path: @test_dir, content: 'oops')
    end
  end

  # mkdir

  def test_mkdir_creates_directory
    dir_path = File.join(@test_dir, 'newdir')

    result = Handlers::Files.mkdir(path: dir_path)

    assert_kind_of Pathname, result
    assert File.directory?(dir_path)
  end

  def test_mkdir_raises_validation_error_if_exists
    assert_raises(Handlers::ValidationError) do
      Handlers::Files.mkdir(path: @test_dir)
    end
  end

  # delete

  def test_delete_removes_file
    file_path = File.join(@test_dir, 'del.txt')
    FileUtils.touch(file_path)

    result = Handlers::Files.delete(path: file_path)

    assert_equal true, result[:deleted]
    refute File.exist?(file_path)
  end

  def test_delete_removes_empty_directory
    dir_path = File.join(@test_dir, 'empty')
    FileUtils.mkdir(dir_path)

    result = Handlers::Files.delete(path: dir_path)

    assert_equal true, result[:deleted]
    refute File.exist?(dir_path)
  end

  def test_delete_raises_validation_error_for_nonempty_directory
    dir_path = File.join(@test_dir, 'nonempty')
    FileUtils.mkdir(dir_path)
    FileUtils.touch(File.join(dir_path, 'child.txt'))

    assert_raises(Handlers::ValidationError) do
      Handlers::Files.delete(path: dir_path)
    end
  end

  def test_delete_recursive_removes_nonempty_directory
    dir_path = File.join(@test_dir, 'recursive')
    FileUtils.mkdir(dir_path)
    FileUtils.touch(File.join(dir_path, 'child.txt'))

    result = Handlers::Files.delete(path: dir_path, recursive: true)

    assert_equal true, result[:deleted]
    refute File.exist?(dir_path)
  end

  def test_delete_raises_not_found
    assert_raises(Handlers::NotFoundError) do
      Handlers::Files.delete(path: File.join(@test_dir, 'gone'))
    end
  end

  # read with max_size

  def test_read_with_max_size_truncates
    file_path = File.join(@test_dir, 'large.txt')
    File.write(file_path, 'a' * 1000)

    result = Handlers::Files.read(path: file_path, max_size: 100)
    assert_equal 100, result.bytesize
  end

  def test_read_without_max_size_returns_full_content
    file_path = File.join(@test_dir, 'small.txt')
    File.write(file_path, 'hello')

    result = Handlers::Files.read(path: file_path)
    assert_equal 'hello', result
  end

  # write with append

  def test_write_append_adds_to_file
    file_path = File.join(@test_dir, 'append.txt')
    File.write(file_path, 'first')

    Handlers::Files.write(path: file_path, content: ' second', append: true)
    assert_equal 'first second', File.read(file_path)
  end

  def test_write_without_append_overwrites
    file_path = File.join(@test_dir, 'overwrite2.txt')
    File.write(file_path, 'old')

    Handlers::Files.write(path: file_path, content: 'new')
    assert_equal 'new', File.read(file_path)
  end

  # normalize_path — tilde expansion

  def test_normalize_path_expands_tilde
    result = Handlers::Files.normalize_path('~/foo')
    assert_equal File.join(Dir.home, 'foo'), result.to_s
  end

  # validate_path! — blocks forbidden paths

  def test_validate_path_blocks_etc_passwd
    path = Pathname.new('/etc/passwd')
    assert_raises(Handlers::ForbiddenError) do
      Handlers::Files.validate_path!(path)
    end
  end

  def test_validate_path_allows_tmp
    path = Pathname.new(File.join(@test_dir, 'ok.txt'))
    # Should not raise
    Handlers::Files.validate_path!(path)
  end
end
