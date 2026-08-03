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

  # A negative max_size used to reach File.read and raise an unrescued
  # ArgumentError, surfacing as a 500 instead of a 400.
  def test_read_with_negative_max_size_raises_validation_error
    file_path = File.join(@test_dir, 'neg.txt')
    File.write(file_path, 'hello')

    assert_raises(Handlers::ValidationError) do
      Handlers::Files.read(path: file_path, max_size: -5)
    end
  end

  def test_read_with_zero_max_size_raises_validation_error
    file_path = File.join(@test_dir, 'zero.txt')
    File.write(file_path, 'hello')

    assert_raises(Handlers::ValidationError) do
      Handlers::Files.read(path: file_path, max_size: 0)
    end
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

  # --- sensitive-path deny-list ---
  #
  # These paths sit inside the user's own home and the user can edit them by
  # other means; the deny-list exists so an agent driving these tools on
  # injected input cannot establish access that outlives the session.

  # A fake home under tmpdir, so tests never touch the real one.
  def with_fake_home
    fake = File.join(@test_dir, 'home')
    FileUtils.mkdir_p(fake)
    Dir.stub(:home, fake) { yield fake }
  end

  def assert_denied(rel)
    with_fake_home do |home|
      path = Handlers::Files.normalize_path(File.join(home, rel))
      assert_raises(Handlers::ForbiddenError, "expected #{rel} to be denied") do
        Handlers::Files.validate_path!(path)
      end
    end
  end

  def assert_allowed(rel)
    with_fake_home do |home|
      path = Handlers::Files.normalize_path(File.join(home, rel))
      Handlers::Files.validate_path!(path) # should not raise
    end
  end

  def test_denies_ssh_directory_and_contents
    assert_denied('.ssh')
    assert_denied('.ssh/authorized_keys')
    assert_denied('.ssh/id_rsa')
  end

  def test_denies_api_token_store
    assert_denied('.config/ondemand/tokens.json')
  end

  def test_denies_shell_init_files
    assert_denied('.bashrc')
    assert_denied('.zshrc')
    assert_denied('.profile')
  end

  def test_denies_systemd_user_units
    assert_denied('.config/systemd/user/evil.service')
  end

  def test_allows_ordinary_paths_that_merely_resemble_denied_ones
    assert_allowed('Documents/notes.txt')
    assert_allowed('.bashrc_backup')
    assert_allowed('sshkeys/mine.pub')
    assert_allowed('.config/other/app.json')
  end

  def test_denies_symlink_pointing_into_denied_directory
    with_fake_home do |home|
      FileUtils.mkdir_p(File.join(home, '.ssh'))
      link = File.join(home, 'sneaky')
      File.symlink(File.join(home, '.ssh'), link)

      path = Handlers::Files.normalize_path(File.join(link, 'authorized_keys'))
      assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.validate_path!(path)
      end
    end
  end

  # A symlink whose target does not exist yet bypassed every layer. `exist?`
  # follows the link, so a dangling one looked missing: validate_path! ascended
  # the LINK's path instead of the target's, so a link in /tmp pointing at
  # ~/.bashrc resolved to /tmp, passed the allowed-roots check, and reached the
  # deny-list as a pair of paths neither of which was under $HOME. The write
  # then followed the link and created the file at the target.
  #
  # Absent files are the ones worth planting: .bashrc and .zshrc are missing on
  # plenty of HPC accounts, and ~/.ssh/authorized_keys on any account that has
  # never used key auth.
  def test_denies_dangling_symlink_pointing_at_a_denied_file
    with_fake_home do |home|
      ['.bashrc', '.zshrc', File.join('.ssh', 'authorized_keys')].each do |rel|
        target = File.join(home, rel)
        link = File.join(Dir.tmpdir, "dangling_#{Process.pid}_#{rel.tr('./', '_')}")
        FileUtils.rm_f([target, link])
        File.symlink(target, link)

        refute File.exist?(target), "#{rel} must not exist for this to be the dangling case"
        assert_raises(Handlers::ForbiddenError, "a dangling link to #{rel} must be refused") do
          Handlers::Files.validate_path!(Handlers::Files.normalize_path(link))
        end
      ensure
        FileUtils.rm_f(link)
      end
    end
  end

  # The link target is resolved lexically against the link's own directory, so
  # a relative target has to be handled too.
  def test_denies_dangling_symlink_with_a_relative_target
    with_fake_home do |home|
      FileUtils.mkdir_p(File.join(home, 'sub'))
      link = File.join(home, 'sub', 'rel_link')
      File.symlink('../.bashrc', link)

      assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.validate_path!(Handlers::Files.normalize_path(link))
      end
    end
  end

  # The guard must not refuse ordinary dangling links. Writing through a link
  # to a file that does not exist yet is normal, and the allowed roots are
  # realpath'd — so the target has to be resolved the same way or every
  # legitimate link in Dir.tmpdir is refused (on macOS /var vs /private/var).
  def test_allows_dangling_symlink_pointing_at_an_allowed_path
    with_fake_home do |home|
      [File.join(home, 'notes.txt'), File.join(Dir.tmpdir, "ok_#{Process.pid}.txt")].each do |target|
        link = "#{target}.link"
        FileUtils.rm_f([target, link])
        File.symlink(target, link)

        Handlers::Files.validate_path!(Handlers::Files.normalize_path(link))
      ensure
        FileUtils.rm_f([target, link])
      end
    end
  end

  # The dangling-leaf guard above does not cover a symlink ABOVE the target.
  # find_real_parent stops at the nearest existing ancestor, so a link like
  # /tmp/hd -> $HOME turns a request for /tmp/hd/.ssh/authorized_keys (leaf and
  # .ssh both absent) into the resolved path $HOME, whose path relative to home
  # is "" and matches no denied entry. The leaf is not itself a symlink, so the
  # dangling guard never fires, and the write landed on the real file.
  def test_denies_denied_path_reached_through_a_symlinked_ancestor
    with_fake_home do |home|
      link_dir = File.join(Dir.tmpdir, "anc_#{Process.pid}")
      FileUtils.rm_f(link_dir)
      File.symlink(home, link_dir)

      ['.bashrc', File.join('.ssh', 'authorized_keys'),
       File.join('.config', 'ondemand', 'tokens.json')].each do |rel|
        target = File.join(home, rel)
        FileUtils.rm_rf(File.dirname(target)) unless File.dirname(target) == home

        assert_raises(Handlers::ForbiddenError, "~/#{rel} must be refused through a symlinked ancestor") do
          Handlers::Files.validate_path!(Handlers::Files.normalize_path(File.join(link_dir, rel)))
        end
      end
    ensure
      FileUtils.rm_f(link_dir)
    end
  end

  # Symlinked ancestors are ordinary in home directories (~/scratch -> /scratch,
  # or a link back to home). Resolving through one must not refuse a legitimate
  # write, including one that creates intermediate directories.
  def test_allows_ordinary_paths_reached_through_a_symlinked_ancestor
    with_fake_home do |home|
      link_dir = File.join(Dir.tmpdir, "anc_ok_#{Process.pid}")
      FileUtils.rm_f(link_dir)
      File.symlink(home, link_dir)

      ['notes.txt', File.join('proj', 'deep', 'f.txt')].each do |rel|
        Handlers::Files.validate_path!(Handlers::Files.normalize_path(File.join(link_dir, rel)))
      end
    ensure
      FileUtils.rm_f(link_dir)
    end
  end

  # macOS and Windows filesystems are usually case-insensitive, so
  # ~/.SSH/authorized_keys IS ~/.ssh/authorized_keys there. The deny-list
  # compared exact case, so the uppercase spelling was permitted and the write
  # landed on the canonical denied file. realpath canonicalises the case once
  # the path exists, so this only bit when the target did not yet exist — the
  # same window the two symlink bypasses used.
  def test_denies_denied_paths_spelled_in_a_different_case
    with_fake_home do |home|
      ['.BASHRC', '.Bashrc', File.join('.SSH', 'authorized_keys'),
       File.join('.Ssh', 'AUTHORIZED_KEYS'),
       File.join('.CONFIG', 'systemd', 'user', 'x.service')].each do |rel|
        target = File.join(home, rel)
        FileUtils.rm_rf(File.dirname(target)) unless File.dirname(target) == home

        assert_raises(Handlers::ForbiddenError, "#{rel} must be refused whatever its case") do
          Handlers::Files.validate_path!(Handlers::Files.normalize_path(target))
        end
      end
    end
  end

  # Case-folding must not widen the match: a name that merely starts with a
  # denied one is still ordinary.
  def test_case_folding_does_not_refuse_ordinary_paths
    with_fake_home do |home|
      ['.bashrc_backup', '.BASHRC_BACKUP', 'notes.txt', 'Documents/README',
       'sshkeys/mine.pub', '.configuration'].each do |rel|
        Handlers::Files.validate_path!(Handlers::Files.normalize_path(File.join(home, rel)))
      end
    end
  end

  # APFS is normalization-insensitive: a name written in NFD reaches the same
  # file as its NFC spelling. The deny-list compares byte-exactly after
  # case-folding, so a non-ASCII entry would be bypassable the same way the
  # uppercase spellings were. Every entry is ASCII today, where NFD and NFC are
  # identical — this fails if that stops being true, so whoever adds such an
  # entry has to normalize the comparison rather than discover it in review.
  def test_deny_list_entries_stay_ascii_so_normalization_cannot_bypass_them
    offenders = (Handlers::Files::DENIED_EXACT + Handlers::Files::DENIED_DIRS).reject(&:ascii_only?)

    assert_empty offenders,
                 'non-ASCII deny entries need unicode_normalize on both sides of the comparison ' \
                 "(APFS treats NFD and NFC as the same file): #{offenders.inspect}"
  end

  # A single readlink follows one hop. With a -> b -> denied and the final
  # target absent, the check saw `b` — an innocuous name — and never examined
  # the real destination. One hop was refused; two were not. This escaped the
  # allowed roots as well as the deny-list, since neither check ever saw where
  # the write would land.
  def test_denies_multi_hop_symlink_chain_to_a_denied_file
    with_fake_home do |home|
      target = File.join(home, '.ssh', 'authorized_keys')
      FileUtils.mkdir_p(File.dirname(target))
      hops = (1..3).map { |i| File.join(home, "hop#{i}") }
      FileUtils.rm_f(hops)

      File.symlink(target, hops[0])
      File.symlink(hops[0], hops[1])
      File.symlink(hops[1], hops[2])

      hops.each_with_index do |link, i|
        assert_raises(Handlers::ForbiddenError, "a #{i + 1}-hop chain to authorized_keys must be refused") do
          Handlers::Files.validate_path!(Handlers::Files.normalize_path(link))
        end
      end
    ensure
      FileUtils.rm_f(hops || [])
    end
  end

  # A chain whose end is outside every allowed root must be refused too — that
  # is confinement, not just the deny-list.
  def test_denies_symlink_chain_leaving_the_allowed_roots
    with_fake_home do |home|
      outside = File.join(__dir__, '..', '..', 'tmp', "chain_escape_#{Process.pid}")
      links = [File.join(home, 'e1'), File.join(home, 'e2')]
      FileUtils.rm_f(links)
      File.symlink(outside, links[0])
      File.symlink(links[0], links[1])

      assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.validate_path!(Handlers::Files.normalize_path(links[1]))
      end
    ensure
      FileUtils.rm_f((links || []) + [outside].compact)
    end
  end

  # A chain that loops must be refused rather than followed forever.
  def test_refuses_a_symlink_loop_without_hanging
    with_fake_home do |home|
      a = File.join(home, 'loop_a')
      b = File.join(home, 'loop_b')
      FileUtils.rm_f([a, b])
      File.symlink(b, a)
      File.symlink(a, b)

      assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.validate_path!(Handlers::Files.normalize_path(a))
      end
    ensure
      FileUtils.rm_f([a, b].compact)
    end
  end

  # Chains to permitted destinations stay usable.
  def test_allows_multi_hop_symlink_chain_to_an_allowed_path
    with_fake_home do |home|
      target = File.join(home, 'ok.txt')
      links = [File.join(home, 'g1'), File.join(home, 'g2')]
      FileUtils.rm_f(links + [target])
      File.symlink(target, links[0])
      File.symlink(links[0], links[1])

      Handlers::Files.validate_path!(Handlers::Files.normalize_path(links[1]))
    ensure
      FileUtils.rm_f((links || []) + [target].compact)
    end
  end

  # A hardlink is a second name for the same inode. realpath resolves it to
  # itself, so name-based checks cannot see the denied original — the deny-list
  # has to compare device+inode.
  def test_denies_hardlink_to_a_denied_file
    with_fake_home do |home|
      FileUtils.mkdir_p(File.join(home, '.ssh'))
      original = File.join(home, '.ssh', 'id_rsa')
      File.write(original, 'PRIVATE KEY')
      alias_path = File.join(home, 'innocent_name')
      File.link(original, alias_path)

      path = Handlers::Files.normalize_path(alias_path)
      error = assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.validate_path!(path)
      end
      assert_match(%r{\.ssh/id_rsa}, error.message, 'should name the real denied path')
    end
  end

  def test_denies_hardlink_to_a_denied_shell_init_file
    with_fake_home do |home|
      original = File.join(home, '.bashrc')
      File.write(original, 'export PATH=/usr/bin')
      alias_path = File.join(home, 'notes.txt')
      File.link(original, alias_path)

      assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.validate_path!(Handlers::Files.normalize_path(alias_path))
      end
    end
  end

  def test_allows_a_hardlink_between_two_ordinary_files
    with_fake_home do |home|
      original = File.join(home, 'data.txt')
      File.write(original, 'ordinary')
      alias_path = File.join(home, 'data_link.txt')
      File.link(original, alias_path)

      Handlers::Files.validate_path!(Handlers::Files.normalize_path(alias_path)) # no raise
    end
  end

  # validate_path! only inspects the target. Recursion would sweep denied paths
  # beneath an allowed parent — deleting ~/.config takes the token store with it.
  def test_recursive_delete_refuses_to_sweep_a_denied_subdirectory
    with_fake_home do |home|
      FileUtils.mkdir_p(File.join(home, '.config', 'ondemand'))
      File.write(File.join(home, '.config', 'ondemand', 'tokens.json'), '[]')

      error = assert_raises(Handlers::ForbiddenError) do
        Handlers::Files.delete(path: File.join(home, '.config'), recursive: true)
      end
      assert_match(%r{\.config/ondemand}, error.message)
      assert File.exist?(File.join(home, '.config', 'ondemand', 'tokens.json')),
             'token store must survive the refused delete'
    end
  end

  def test_recursive_delete_of_an_ordinary_tree_still_works
    with_fake_home do |home|
      tree = File.join(home, 'scratch', 'nested')
      FileUtils.mkdir_p(tree)
      File.write(File.join(tree, 'f.txt'), 'x')

      Handlers::Files.delete(path: File.join(home, 'scratch'), recursive: true)
      refute File.exist?(File.join(home, 'scratch'))
    end
  end

  # A full disk or exhausted quota is a 507, not a 500. Only `write` mapped
  # these; touch and mkdir let the raw Errno escape as an unexplained 500.
  # EDQUOT matters more than ENOSPC in practice — per-user home quotas are
  # routine on HPC sites.
  def test_touch_maps_out_of_space_to_storage_error
    with_fake_home do |home|
      target = File.join(home, 'f.txt')
      FileUtils.stubs(:touch).raises(Errno::ENOSPC)
      assert_raises(Handlers::StorageError) { Handlers::Files.touch(path: target) }
    end
  end

  def test_mkdir_maps_out_of_space_to_storage_error
    with_fake_home do |home|
      Pathname.any_instance.stubs(:mkpath).raises(Errno::ENOSPC)
      assert_raises(Handlers::StorageError) { Handlers::Files.mkdir(path: File.join(home, 'd')) }
    end
  end

  def test_quota_exceeded_is_reported_distinctly
    with_fake_home do |home|
      FileUtils.stubs(:touch).raises(Errno::EDQUOT)
      err = assert_raises(Handlers::StorageError) { Handlers::Files.touch(path: File.join(home, 'f.txt')) }
      assert_match(/quota/i, err.message)
    end
  end

  # Reading a FIFO blocks in read(2) until someone writes, wedging the
  # Passenger worker; with passenger_min_instances 0 that takes the app down
  # for that user. Device nodes are worse — /dev/zero never ends.
  def test_read_refuses_a_fifo_instead_of_blocking
    with_fake_home do |home|
      fifo = File.join(home, 'pipe')
      begin
        File.mkfifo(fifo)
      rescue NotImplementedError, Errno::EPERM
        skip 'mkfifo unavailable'
      end

      err = assert_raises(Handlers::ValidationError) { Handlers::Files.read(path: fifo) }
      assert_match(/regular file/i, err.message)
    end
  end

  def test_read_still_accepts_an_ordinary_file
    with_fake_home do |home|
      f = File.join(home, 'ok.txt')
      File.write(f, 'hello')
      assert_equal 'hello', Handlers::Files.read(path: f)
    end
  end

  # ENOTDIR/ELOOP/ENAMETOOLONG are the caller's mistake, not a server fault.
  # They escaped as blank 500s on REST and -32603 on MCP.
  def test_write_under_a_non_directory_is_a_validation_error
    with_fake_home do |home|
      plain = File.join(home, 'plain.txt')
      File.write(plain, 'x')

      assert_raises(Handlers::ValidationError) do
        Handlers::Files.write(path: File.join(plain, 'child.txt'), content: 'x')
      end
    end
  end

  def test_overlong_name_is_a_validation_error
    with_fake_home do |home|
      assert_raises(Handlers::ValidationError) do
        Handlers::Files.write(path: File.join(home, 'a' * 300), content: 'x')
      end
    end
  end

  # The encoding guard protects the security check itself. Pathname#ascend
  # matches against a regex and raises ArgumentError on invalid UTF-8, and
  # validate_path! reaches it via find_real_parent — so one stray byte crashed
  # out of the allowed-roots and deny-list checks before they reached a
  # verdict, surfacing as a 500 instead of a refusal.
  def test_invalid_utf8_path_is_rejected_before_the_deny_list_runs
    bad = (+'/tmp/x').force_encoding('UTF-8') << 255.chr('BINARY').force_encoding('UTF-8')

    err = assert_raises(Handlers::ValidationError) { Handlers::Files.list(path: bad) }
    assert_match(/UTF-8/, err.message)
  end

  def test_null_byte_path_is_rejected
    err = assert_raises(Handlers::ValidationError) { Handlers::Files.list(path: "/tmp/x\0.txt") }
    assert_match(/null byte/, err.message)
  end
end
