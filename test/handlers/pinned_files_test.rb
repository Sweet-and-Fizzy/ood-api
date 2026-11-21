# frozen_string_literal: true

require 'timeout'
require_relative '../test_helper'
require_relative '../../app/handlers/files'
require_relative '../../app/mcp_tools/files'

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

  # A recursive delete that walked the tree by name could be steered: whoever
  # owns a subdirectory swaps it for a symlink mid-walk, and the contents of
  # the link's target are deleted instead.
  def test_recursive_delete_never_follows_a_swapped_subdirectory
    precious = File.join(@home, 'precious')
    FileUtils.mkdir_p(precious)
    20.times { |i| File.write(File.join(precious, "keep#{i}"), 'x') }
    cache = File.join(@shared, 'cache')
    FileUtils.mkdir_p(cache)
    flipper = fork_subdir_flipper(cache, precious)

    Dir.stub(:home, @home) do
      deadline = Time.now + 6
      attempt do
        files.delete(path: cache, recursive: true)
      end while Time.now < deadline && Dir.children(precious).size == 20
    end

    assert_equal 20, Dir.children(precious).size, 'files outside the deleted tree were removed'
  ensure
    if flipper
      Process.kill('KILL', flipper)
      Process.wait(flipper)
    end
  end

  # Keeps `base/sub` alternating between a real directory and a symlink to
  # `target`, by rename so there is never a moment when it is missing, and
  # puts the directory back whenever the delete under test removes it.
  def fork_subdir_flipper(base, target)
    fork do
      real = File.join(base, 'sub.real')
      link = File.join(base, 'sub.lnk')
      sub = File.join(base, 'sub')
      loop do
        restore_flip_pieces(real, link, sub, target)
        50.times do
          [[real, sub], [sub, real], [link, sub], [sub, link]].each do |from, dest|
            rename_quietly(from, dest)
          end
        end
      end
    end
  end

  def restore_flip_pieces(real, link, sub, target)
    FileUtils.mkdir_p(real) unless File.directory?(sub) && !File.symlink?(sub)
    File.write(File.join(real, 'f'), 'x') if File.directory?(real)
    File.symlink(target, link) unless File.symlink?(link) || File.symlink?(sub)
  rescue SystemCallError
    nil
  end

  def rename_quietly(from, dest)
    File.rename(from, dest)
  rescue SystemCallError
    nil
  end

  # Parents used to be created before the final check, so a refused write
  # could still leave ~/.ssh behind.
  def test_a_refused_write_creates_no_parent_directories
    FileUtils.rm_rf(@ssh)

    with_swap(@home) do
      assert_raises(Handlers::ForbiddenError) do
        files.write(path: File.join(@dir, '.ssh', 'authorized_keys'), content: 'k')
      end
    end

    refute File.exist?(@ssh), '~/.ssh was created by a write that was refused'
  end

  def test_touch_on_a_directory_does_not_follow_a_swapped_symlink
    key = File.join(@ssh, 'id_rsa')
    old = Time.now - 86_400
    File.utime(old, old, key)
    sub = File.join(@dir, 'sub')
    FileUtils.mkdir_p(sub)

    Dir.stub(:home, @home) do
      original = Handlers::PinnedDir.instance_method(:lstat)
      Handlers::PinnedDir.define_method(:lstat) do |name|
        result = original.bind_call(self, name)
        if name == 'sub' && File.directory?(sub) && !File.symlink?(sub)
          Dir.rmdir(sub)
          File.symlink(key, sub)
        end
        result
      end
      begin
        attempt { files.touch(path: sub) }
      ensure
        Handlers::PinnedDir.define_method(:lstat, original)
      end
    end

    assert_in_delta old, File.mtime(key), 2, 'the swapped-in target had its times changed'
  end

  # The kernel will not follow another user's symlink in a sticky directory.
  # Following it by hand would sidestep that.
  def test_another_users_symlink_is_not_followed
    Dir.stub(:home, @home) do
      target = File.join(@home, 'mine.txt')
      File.write(target, 'mine')
      link = File.join(@shared, 'theirs')
      File.symlink(target, link)
      Process.stubs(:euid).returns(Process.uid + 1)

      assert_raises(Handlers::ForbiddenError) { files.write(path: link, content: 'overwritten') }
      assert_equal 'mine', File.read(target)
    end
  end

  # Linux file names are bytes. One that is not UTF-8 must not hide the rest.
  def test_a_name_that_is_not_utf8_does_not_break_the_listing
    Dir.stub(:home, @home) do
      File.write(File.join(@dir, "bad\xFFname".b), 'x')
      File.write(File.join(@dir, 'good'), 'x')

      names = files.list(path: @dir).map { |entry| entry.basename.to_s.b }
      text = OodApi::Tools::ListFilesTool.run(path: @dir).content.first[:text]
      assert_includes text, 'good'

      assert_equal ["bad\xFFname".b, 'good'.b], names.sort
    end
  end

  # The check is made on the open file, so it holds whatever name led to it.
  def test_a_hardlink_to_a_denied_file_is_refused_on_the_open_file
    Dir.stub(:home, @home) do
      link = File.join(@home, 'innocent.txt')
      File.link(File.join(@ssh, 'id_rsa'), link)
      original = files.method(:deny_by_inode!)
      files.define_singleton_method(:deny_by_inode!) { |_path| nil }
      begin
        assert_raises(Handlers::ForbiddenError) { files.read(path: link) }
        assert_raises(Handlers::ForbiddenError) { files.write(path: link, content: 'overwritten') }
        assert_raises(Handlers::ForbiddenError) { files.touch(path: link) }
      ensure
        files.define_singleton_method(:deny_by_inode!, original)
      end
      assert_equal 'PRIVATE KEY', File.read(File.join(@ssh, 'id_rsa'))
    end
  end

  # An empty directory needs no reading to be removed.
  def test_recursive_delete_removes_an_empty_directory_it_cannot_read
    skip 'root reads everything' if Process.uid.zero?
    Dir.stub(:home, @home) do
      tree = File.join(@home, 'tree')
      FileUtils.mkdir_p(File.join(tree, 'locked'))
      File.chmod(0o000, File.join(tree, 'locked'))

      files.delete(path: tree, recursive: true)

      refute File.exist?(tree)
    end
  end

  def test_out_of_space_is_a_storage_error
    Dir.stub(:home, @home) do
      Dir.stubs(:mkdir).raises(Errno::EDQUOT)
      err = assert_raises(Handlers::StorageError) { files.mkdir(path: File.join(@home, 'd')) }
      assert_match(/quota/i, err.message)

      File.stubs(:open).raises(Errno::ENOSPC)
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
