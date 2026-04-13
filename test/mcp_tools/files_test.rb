# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/files'
require 'tmpdir'

class ListFilesToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('mcp_files_test')
    FileUtils.touch(File.join(@tmpdir, 'a.txt'))
    FileUtils.touch(File.join(@tmpdir, 'b.txt'))
    FileUtils.mkdir(File.join(@tmpdir, 'subdir'))
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_lists_directory
    result = ListFilesTool.call(server_context: nil, path: @tmpdir)
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, 'a.txt'
    assert_includes text, 'b.txt'
    assert_includes text, 'subdir'
  end

  def test_error_on_missing_path
    result = ListFilesTool.call(server_context: nil, path: File.join(@tmpdir, 'nope'))
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'not found'
  end
end

class ReadFileToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('mcp_files_test')
    @file = File.join(@tmpdir, 'hello.txt')
    File.write(@file, 'Hello, world!')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_reads_file
    result = ReadFileTool.call(server_context: nil, path: @file)
    content = result.to_h
    refute content[:isError]
    assert_equal 'Hello, world!', content[:content].first[:text]
  end

  def test_error_on_missing_file
    result = ReadFileTool.call(server_context: nil, path: File.join(@tmpdir, 'nope.txt'))
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'not found'
  end
end

class WriteFileToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('mcp_files_test')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_writes_file
    path = File.join(@tmpdir, 'out.txt')
    result = WriteFileTool.call(server_context: nil, path: path, content: 'test content')
    content = result.to_h
    refute content[:isError]
    assert_includes content[:content].first[:text], 'File written'
    assert_equal 'test content', File.read(path)
  end

  def test_error_on_forbidden_path
    result = WriteFileTool.call(server_context: nil, path: '/etc/test-file.txt', content: 'bad')
    content = result.to_h
    assert content[:isError]
  end
end

class ReadFileToolMaxSizeTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir('mcp_files_test')
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_read_file_with_max_size
    File.write(File.join(@test_dir, 'big.txt'), 'a' * 1000)
    result = ReadFileTool.call(path: File.join(@test_dir, 'big.txt'), max_size: 50, server_context: nil)
    refute result.to_h[:isError]
    assert_equal 50, result.to_h[:content].first[:text].bytesize
  end
end

class WriteFileToolAppendTest < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir('mcp_files_test')
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_write_file_append
    path = File.join(@test_dir, 'appendable.txt')
    File.write(path, 'first')
    result = WriteFileTool.call(path: path, content: ' second', append: true, server_context: nil)
    refute result.to_h[:isError]
    assert_equal 'first second', File.read(path)
  end
end

class CreateDirectoryToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('mcp_files_test')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_creates_directory
    path = File.join(@tmpdir, 'newdir')
    result = CreateDirectoryTool.call(server_context: nil, path: path)
    content = result.to_h
    refute content[:isError]
    assert_includes content[:content].first[:text], 'Directory created'
    assert File.directory?(path)
  end

  def test_error_on_existing_path
    result = CreateDirectoryTool.call(server_context: nil, path: @tmpdir)
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'already exists'
  end
end

class DeleteFileToolTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir('mcp_files_test')
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_deletes_file
    path = File.join(@tmpdir, 'delete_me.txt')
    File.write(path, 'bye')
    result = DeleteFileTool.call(server_context: nil, path: path)
    content = result.to_h
    refute content[:isError]
    assert_includes content[:content].first[:text], 'Deleted'
    refute File.exist?(path)
  end

  def test_error_on_missing_file
    result = DeleteFileTool.call(server_context: nil, path: File.join(@tmpdir, 'nope'))
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'not found'
  end
end
