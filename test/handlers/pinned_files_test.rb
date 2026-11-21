# frozen_string_literal: true

require 'timeout'
require_relative '../test_helper'
require_relative '../../app/handlers/files'

# Path-swap races. A directory another user controls is re-pointed at a
# protected location between the policy check and the file operation. These
# run only where PinnedDir is supported (Linux), which is where the app is
# deployed; elsewhere the weaker before-and-after check applies.
class PinnedFilesTest < Minitest::Test
  def setup
    skip 'needs /proc/self/fd' unless Handlers::PinnedDir.supported?

    @root = Dir.mktmpdir('ood-api-pinned')
    @home = File.join(@root, 'home')
    @shared = File.join(@root, 'shared')
    @outside = File.join(@root, 'outside')
    @ssh = File.join(@home, '.ssh')
    [@ssh, @shared, @outside].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(@ssh, 'id_rsa'), 'PRIVATE KEY')
    ENV['OOD_ALLOWLIST_PATH'] = "#{@home}:#{@shared}"
    @dir = File.join(@shared, 'd')
    FileUtils.mkdir_p(@dir)
  end

  def teardown
    ENV.delete('OOD_ALLOWLIST_PATH')
    FileUtils.rm_rf(@root) if @root
  end

  def files
    Handlers::Files
  end

  # Swaps `shared/d` for a symlink to `target` at the worst moment: straight
  # after the string-level check has passed.
  def swap_dir_to(target)
    lambda do
      FileUtils.rm_rf(@dir)
      File.symlink(target, @dir)
    end
  end

  def with_swap(target)
    Dir.stub(:home, @home) do
      original = files.method(:validate_path!)
      swap = swap_dir_to(target)
      files.define_singleton_method(:validate_path!) do |path|
        result = original.call(path)
        swap&.call
        swap = nil
        result
      end
      begin
        yield
      ensure
        files.define_singleton_method(:validate_path!, original)
      end
    end
  end

  def test_write_does_not_land_in_a_denied_directory_and_leaves_nothing_behind
    File.write(File.join(@dir, 'authorized_keys'), 'decoy')

    with_swap(@ssh) do
      assert_raises(Handlers::ForbiddenError) do
        files.write(path: File.join(@dir, 'authorized_keys'), content: 'ssh-ed25519 ATTACKER')
      end
    end

    refute File.exist?(File.join(@ssh, 'authorized_keys')), 'not even an empty file may be created'
  end

  def test_read_does_not_return_a_denied_file
    File.write(File.join(@dir, 'id_rsa'), 'decoy')

    with_swap(@ssh) do
      assert_raises(Handlers::ForbiddenError) { files.read(path: File.join(@dir, 'id_rsa')) }
    end
  end

  def test_nothing_is_read_written_or_created_outside_the_allowed_roots
    File.write(File.join(@outside, 'secret'), 'OUTSIDE')
    File.write(File.join(@dir, 'secret'), 'decoy')

    with_swap(@outside) do
      assert_raises(Handlers::ForbiddenError) { files.read(path: File.join(@dir, 'secret')) }
    end
    FileUtils.rm_rf(@dir)
    FileUtils.mkdir_p(@dir)
    with_swap(@outside) do
      assert_raises(Handlers::ForbiddenError) { files.write(path: File.join(@dir, 'a/b/c/new'), content: 'x') }
    end

    refute File.exist?(File.join(@outside, 'a')), 'no directory may be created through the swapped parent'
  end

  def test_touch_mkdir_delete_and_list_are_covered_too
    with_swap(@ssh) do
      assert_raises(Handlers::ForbiddenError) { files.touch(path: File.join(@dir, 'authorized_keys')) }
    end
    refute File.exist?(File.join(@ssh, 'authorized_keys'))

    reset_dir
    with_swap(@ssh) do
      assert_raises(Handlers::ForbiddenError) { files.mkdir(path: File.join(@dir, 'newdir')) }
    end
    refute File.exist?(File.join(@ssh, 'newdir'))

    reset_dir
    File.write(File.join(@dir, 'id_rsa'), 'decoy')
    with_swap(@ssh) do
      assert_raises(Handlers::ForbiddenError) { files.delete(path: File.join(@dir, 'id_rsa')) }
    end
    assert File.exist?(File.join(@ssh, 'id_rsa')), 'the private key must survive'

    reset_dir
    with_swap(@ssh) do
      assert_raises(Handlers::ForbiddenError) { files.list(path: @dir) }
    end
  end

  def reset_dir
    FileUtils.rm_rf(@dir)
    FileUtils.mkdir_p(@dir)
  end

  # A leaf swapped for a symlink after it was looked at is refused, not followed.
  def test_a_leaf_swapped_for_a_symlink_is_not_followed
    Dir.stub(:home, @home) do
      leaf = File.join(@dir, 'f')
      File.symlink(File.join(@home, '.bashrc'), leaf)

      assert_raises(Handlers::ForbiddenError) { files.write(path: leaf, content: 'k') }
      refute File.exist?(File.join(@home, '.bashrc'))
    end
  end

  # No instrumentation: a second process flips the directory as fast as it
  # can while this one writes and reads through it.
  def test_real_race_against_a_flipping_symlink
    real = File.join(@shared, 'r_real')
    FileUtils.mkdir_p(real)
    File.write(File.join(real, 'authorized_keys'), 'decoy')
    File.write(File.join(real, 'id_rsa'), 'decoy')
    link = File.join(@shared, 'r')
    File.symlink(real, link)
    flipper = fork_flipper(link, real)

    leaked = 0
    Dir.stub(:home, @home) do
      Timeout.timeout(60) do
        3000.times do
          attempt { files.write(path: File.join(link, 'authorized_keys'), content: 'ATTACKER') }
          leaked += 1 if attempt { files.read(path: File.join(link, 'id_rsa')) } == 'PRIVATE KEY'
        end
      end
    end

    refute File.exist?(File.join(@ssh, 'authorized_keys')), 'a write reached ~/.ssh'
    assert_equal 0, leaked, 'a read returned the private key'
  ensure
    if flipper
      Process.kill('KILL', flipper)
      Process.wait(flipper)
    end
  end

  # A refusal is the expected outcome of most attempts.
  def attempt
    yield
  rescue Handlers::Error
    nil
  end

  def fork_flipper(link, real)
    ssh = @ssh
    shared = @shared
    fork do
      a = File.join(shared, 'tmp_a')
      b = File.join(shared, 'tmp_b')
      loop do
        File.symlink(ssh, a)
        File.rename(a, link)
        File.symlink(real, b)
        File.rename(b, link)
      rescue SystemCallError
        nil
      end
    end
  end

  def test_out_of_space_is_a_storage_error
    Dir.stub(:home, @home) do
      Dir.stubs(:mkdir).raises(Errno::EDQUOT)
      err = assert_raises(Handlers::StorageError) { files.mkdir(path: File.join(@home, 'd')) }
      assert_match(/quota/i, err.message)

      File.stubs(:utime).raises(Errno::ENOSPC)
      assert_raises(Handlers::StorageError) { files.touch(path: File.join(@home, 'f.txt')) }
    end
  end

  def test_ordinary_operations_still_work
    Dir.stub(:home, @home) do
      file = File.join(@home, 'work', 'deep', 'notes.txt')
      files.write(path: file, content: 'hello')
      files.write(path: file, content: ' world', append: true)
      assert_equal 'hello world', files.read(path: file)

      link = File.join(@home, 'link.txt')
      File.symlink(file, link)
      files.write(path: link, content: 'via link')
      assert_equal 'via link', File.read(file)

      files.mkdir(path: File.join(@home, 'made', 'here'))
      files.touch(path: File.join(@home, 'made', 'here', 'empty'))
      names = files.list(path: File.join(@home, 'made', 'here')).map { |c| c.basename.to_s }
      assert_equal ['empty'], names
      files.delete(path: File.join(@home, 'made'), recursive: true)
      refute File.exist?(File.join(@home, 'made'))
    end
  end
end
