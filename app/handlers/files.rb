# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'etc'
require 'tmpdir'
require_relative 'errors'
require_relative '../../lib/site_config'
require_relative 'pinned_dir'

module Handlers
  module Files
    MAX_FILE_READ  = ENV.fetch('OOD_API_MAX_FILE_READ', 10 * 1024 * 1024).to_i
    MAX_FILE_WRITE = ENV.fetch('OOD_API_MAX_FILE_WRITE', 50 * 1024 * 1024).to_i

    # Every way the filesystem says "no room", mapped to 507 rather than a bare
    # 500. EDQUOT is the one that actually bites on HPC sites — a per-user home
    # quota is far more common than a genuinely full filesystem — and ENOSPC
    # covers exhausted inodes as well as exhausted blocks. Errno constants are
    # platform-dependent, so look them up rather than naming them directly.
    OUT_OF_SPACE_ERRORS = [:ENOSPC, :EDQUOT, :EFBIG].filter_map do |name|
      Errno.const_get(name) if Errno.const_defined?(name)
    end.freeze

    # Filesystem complaints about the shape of the path itself. Each is the
    # caller's mistake, not a server fault: a component that is not a directory,
    # a symlink loop, or a name longer than the filesystem allows. They escaped
    # as blank 500s on REST and as -32603 protocol errors on MCP.
    #
    # EEXIST is here because a symlink loop makes `exist?` false — the kernel
    # answers ELOOP, not "no" — so `mkpath` runs on a parent that is already
    # there and raises. Listing it centrally keeps every method that shares
    # this rescue consistent; mkdir additionally maps it to its own message.
    BAD_PATH_ERRORS = [:ENOTDIR, :ELOOP, :ENAMETOOLONG, :EISDIR, :EINVAL, :EEXIST].filter_map do |name|
      Errno.const_get(name) if Errno.const_defined?(name)
    end.freeze

    def self.out_of_space_message(err)
      case err
      when Errno::EDQUOT then 'Disk quota exceeded'
      when Errno::EFBIG then 'File too large for the filesystem'
      else 'No space left on device'
      end
    end

    # --- public API ---

    def self.list(path:)
      p = normalize_path(path)
      validate_path!(p)
      raise NotFoundError, 'Path not found' unless p.exist?

      return p unless p.directory?

      children = PinnedDir.supported? ? PinnedFiles.children(p).map { |name| p + name } : p.children
      children.select(&:readable?).sort_by { |c| [c.directory? ? 0 : 1, c.basename.to_s.downcase] }
    rescue Errno::ENOENT
      raise NotFoundError, 'Path not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    # True only for a value that converts to a positive integer. Infinity and
    # NaN raise from to_i rather than returning something comparable, so the
    # conversion has to be guarded rather than trusted.
    def self.positive_size?(value)
      Integer(value).positive?
    rescue TypeError, ArgumentError, RangeError
      false
    end

    def self.read(path:, max_size: nil)
      # Guard here as well as at the route: MCP passes max_size straight
      # through, and a negative would reach File.read and raise ArgumentError.
      # `to_i` is not safe on its own — JSON's `1e400` parses to
      # Float::INFINITY, whose to_i raises FloatDomainError. The REST route's
      # /\A\d+\z/ blocks that spelling, so MCP was the only way in.
      raise ValidationError, 'max_size must be greater than zero' if max_size && !positive_size?(max_size)

      p = normalize_path(path)
      validate_path!(p)
      effective_limit = max_size ? [max_size, MAX_FILE_READ].min : MAX_FILE_READ
      return PinnedFiles.read(p, limit: effective_limit, refuse_larger: !max_size) if PinnedDir.supported?

      readable_file!(p)
      expected = checked_destination(p)
      File.open(p.to_s, File::RDONLY | File::NONBLOCK) do |f|
        verify_open_file!(f, p, expected)
        if !max_size && (f.stat.size > effective_limit)
          raise PayloadTooLargeError, "File too large (max #{effective_limit} bytes)"
        end

        f.read(effective_limit) || ''
      end
    rescue Errno::ENOENT
      raise NotFoundError, 'File not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    def self.readable_file!(path)
      raise NotFoundError, 'File not found' unless path.exist?
      raise ValidationError, 'Cannot read directory contents' if path.directory?
      # Regular files only. Reading a FIFO blocks in read(2) until someone
      # writes, which wedges the Passenger worker indefinitely — with
      # passenger_min_instances 0 that takes the app down for the user. Device
      # nodes are worse still: /dev/zero never ends. Nothing legitimate here
      # reads a non-regular file, and an agent can be talked into trying.
      raise ValidationError, 'Not a regular file' unless path.file?
      raise ForbiddenError, 'Permission denied' unless path.readable?
    end

    def self.write(path:, content:, append: false)
      p = normalize_path(path)
      validate_path!(p)
      raise ValidationError, 'Cannot write to directory' if p.exist? && p.directory?
      raise PayloadTooLargeError, "Content too large (max #{MAX_FILE_WRITE} bytes)" if content.bytesize > MAX_FILE_WRITE

      if PinnedDir.supported?
        PinnedFiles.write(p, content, append: append)
        return p
      end

      p.parent.mkpath unless p.parent.exist?
      expected = checked_destination(p)
      # No O_TRUNC: nothing is destroyed until the open file has been checked.
      flags = File::WRONLY | File::CREAT | File::NONBLOCK | (append ? File::APPEND : 0)
      File.open(p.to_s, flags) do |f|
        verify_open_file!(f, p, expected)
        f.truncate(0) unless append
        f.write(content)
      end
      p
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue Errno::ENXIO
      # A FIFO with no reader. With one, the open succeeds and the type check
      # in verify_open_file! refuses it.
      raise ValidationError, 'Not a regular file'
    rescue Errno::ENOENT
      raise NotFoundError, 'Path not found'
    rescue *OUT_OF_SPACE_ERRORS => e
      raise StorageError, out_of_space_message(e)
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    # Removing a symlink unlinks the link and never touches its target, so the
    # policy applies to where the link is, not to where it points. Judging it
    # by its target made a dangling link, or one pointing outside the allowed
    # roots, impossible to remove.
    def self.validate_link_location!(link)
      location = link.parent.realpath.join(link.basename)
      unless allowed_path_roots.any? { |root| path_under?(location, root) }
        raise ForbiddenError, 'Access denied: path not in allowed directories'
      end

      deny_sensitive!(link, location)
    end

    # The policy applied to a path the kernel has already resolved, so there
    # is nothing left in it to re-point: it must be inside an allowed root and
    # must not be, or be an alias of, anything on the deny-list.
    def self.validate_real!(real)
      unless allowed_path_roots.any? { |root| path_under?(real, root) }
        raise ForbiddenError, 'Access denied: path not in allowed directories'
      end

      deny_sensitive!(real, real)
      deny_aliases!(real)
      deny_by_inode!(real)
    end

    # Used where PinnedDir is not supported. Resolves the path first and
    # applies the policy to the result, so the destination the open is later
    # compared against is one that was itself checked.
    def self.checked_destination(path)
      expected = expected_destination(path)
      validate_real!(expected)
      expected
    end

    # Where an open of `path` should land, worked out before the open.
    def self.expected_destination(path)
      return path.realpath if path.exist?

      target = path.symlink? ? resolve_link_chain(path) : path
      target.parent.realpath.join(target.basename)
    end

    # validate_path! judges a path string, and the open that follows resolves
    # it again. In a shared directory such as /tmp, another user who owns a
    # parent directory can swap a component for a symlink between the two, so
    # the open lands on a file the check never saw. This runs on the open
    # descriptor: it must be a regular file (a FIFO or device would block or
    # never end), the path must still resolve to where it did when it was
    # validated, and the descriptor must be that same file.
    def self.verify_open_file!(file, path, expected)
      stat = file.stat
      raise ValidationError, 'Not a regular file' unless stat.file?

      actual = Pathname.new(File.realpath(path.to_s))
      on_disk = actual.stat
      return if actual == expected && on_disk.dev == stat.dev && on_disk.ino == stat.ino

      raise ForbiddenError, 'Access denied: path changed during the operation'
    rescue Errno::ENOENT
      raise ForbiddenError, 'Access denied: path changed during the operation'
    end

    def self.mkdir(path:)
      p = normalize_path(path)
      validate_path!(p)
      raise ValidationError, 'Path already exists' if p.exist?

      PinnedDir.supported? ? PinnedFiles.mkdir(p) : p.mkpath
      p
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue Errno::EEXIST
      raise ValidationError, 'Path already exists'
    rescue *OUT_OF_SPACE_ERRORS => e
      raise StorageError, out_of_space_message(e)
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    def self.touch(path:)
      p = normalize_path(path)
      validate_path!(p)

      PinnedDir.supported? ? PinnedFiles.touch(p) : FileUtils.touch(p)
      p
    rescue Errno::ENOENT
      raise NotFoundError, 'Path not found'
    rescue Errno::ENXIO
      raise ValidationError, 'Not a regular file'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue *OUT_OF_SPACE_ERRORS => e
      raise StorageError, out_of_space_message(e)
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    def self.delete(path:, recursive: false)
      p = normalize_path(path)
      p.symlink? ? validate_link_location!(p) : validate_path!(p)
      raise NotFoundError, 'Path not found' unless p.exist? || p.symlink?

      if PinnedDir.supported?
        PinnedFiles.delete(p, recursive: recursive)
        return { path: p.to_s, deleted: true }
      end

      # A symlink is removed as a link, whatever it points at. `directory?`
      # follows links, so a link to a directory used to reach rmdir and fail.
      if p.symlink? || !p.directory?
        p.delete
      elsif recursive
        # validate_path! only checked the target. Recursion would sweep any
        # denied path beneath it — deleting ~/.config takes ~/.config/ondemand
        # (the token store) with it, and deleting ~ takes ~/.ssh.
        deny_recursive!(p)
        FileUtils.rm_rf(p)
      else
        raise ValidationError, 'Directory not empty' unless p.children.empty?

        p.rmdir
      end

      { path: p.to_s, deleted: true }
    rescue Errno::ENOENT
      raise NotFoundError, 'Path not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue Errno::ENOTEMPTY
      raise ValidationError, 'Directory not empty'
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    # --- path validation ---

    # Single chokepoint for every file operation, so path-shape rejections
    # belong here rather than in each caller.
    #
    # The encoding check guards the security check itself: Pathname#ascend
    # matches against a regex, which raises ArgumentError on invalid UTF-8, and
    # validate_path! calls it via find_real_parent. So a path with one stray
    # byte crashed out of the allowed-roots and deny-list checks before they
    # could reach a verdict — a 500 rather than a refusal. Reject it here, as a
    # malformed request, so the checks always run on something well-formed.
    def self.normalize_path(path_str)
      raw = path_str.to_s
      raise ValidationError, 'path contains a null byte' if raw.include?("\0")
      raise ValidationError, 'path is not valid UTF-8' unless raw.valid_encoding?

      Pathname.new(File.expand_path(raw))
    rescue ArgumentError
      # File.expand_path raises for `~name` when there is no such user.
      raise ValidationError, 'path could not be expanded'
    end

    def self.validate_path!(path)
      allowed_roots = allowed_path_roots
      real_path = path.exist? ? path.realpath : find_real_parent(path)
      allowed = allowed_roots.any? { |root| path_under?(real_path, root) }
      raise ForbiddenError, 'Access denied: path not in allowed directories' unless allowed

      deny_sensitive!(path, real_path)
      # real_path stops at the nearest existing ancestor, which is not where
      # the write lands when a component above the target is a symlink. Check
      # the true destination against both the allowed roots and the deny-list.
      destination = resolved_destination(path)
      unless allowed_roots.any? { |root| path_under?(destination, root) }
        raise ForbiddenError, 'Access denied: path not in allowed directories'
      end

      # Order matters and is load-bearing. resolved_destination resolves
      # symlinked ANCESTORS but not a symlinked leaf; resolve_link_chain,
      # inside deny_dangling_symlink!, resolves a leaf chain but not its
      # ancestors. Neither is complete alone, and they disagree for a leaf
      # link whose own path runs through a symlinked directory. The accurate
      # one for that shape must vote first, so do not move the checks above
      # below this line.
      deny_sensitive!(path, destination)
      deny_aliases!(destination)
      deny_dangling_symlink!(path)
      deny_by_inode!(path)
    end

    # Follow a symlink chain to its end, lexically. realpath cannot do this
    # when the final target does not exist, which is the whole case this
    # guards. A single readlink is not enough either: with a -> b -> denied,
    # one hop reports `b`, an innocuous name, and the real destination is
    # never examined — that let a two-hop chain write outside every allowed
    # root, not just past the deny-list.
    MAX_SYMLINK_HOPS = 32

    def self.resolve_link_chain(path)
      current = path
      MAX_SYMLINK_HOPS.times do
        return current unless current.symlink?

        current = Pathname.new(File.expand_path(File.readlink(current.to_s), current.dirname.to_s))
      end
      # Still a link after the cap: a loop, or nested past anything legitimate.
      raise ForbiddenError, 'Access denied: symbolic link could not be resolved'
    end

    # A symlink whose target does not exist yet defeats every other check here.
    # `exist?` follows the link, so a dangling one is "missing": validate_path!
    # takes find_real_parent, which ascends the LINK's own path and reports the
    # link's directory rather than the target's. A link at /tmp/x -> ~/.bashrc
    # therefore resolves to /tmp, passes the allowed-roots test, and reaches
    # deny_sensitive! as the pair (/tmp/x, /tmp) — neither is under $HOME, so
    # the deny-list never fires. deny_by_inode! then returns early for the same
    # reason. The subsequent write follows the link and creates the file at the
    # target.
    #
    # That is the persistence case the deny-list exists to stop, and absent
    # files are exactly the ones worth planting: .bashrc and .zshrc are missing
    # on plenty of HPC accounts, and ~/.ssh/authorized_keys on any account that
    # has never used key auth.
    #
    # readlink is resolved lexically against the link's directory rather than
    # with realpath, because realpath on a dangling link raises ENOENT — the
    # very case this guards. Relative targets ("../../.bashrc") resolve
    # correctly through expand_path.
    def self.deny_dangling_symlink!(path)
      return unless path.symlink?

      target = resolve_link_chain(path)
      # The allowed roots are realpath'd, so the target must be too or nothing
      # matches: on macOS Dir.tmpdir is /var/folders/... while its realpath is
      # /private/var/folders/.... The target itself may not exist, so resolve
      # through its nearest existing ancestor, as validate_path! does.
      resolved = target.exist? ? target.realpath : resolved_destination(target)

      deny_sensitive!(target, resolved)
      raise ForbiddenError, 'Access denied: path not in allowed directories' unless
        allowed_path_roots.any? { |root| path_under?(resolved, root) }
    rescue SystemCallError
      # Unreadable link: refuse rather than guess where it points.
      raise ForbiddenError, 'Access denied: symbolic link could not be resolved'
    end

    # Name-based checks cannot see a hardlink: a second name for a denied
    # inode resolves to itself, so realpath reports the alias, not the
    # original. Compare device+inode against the denied files themselves.
    def self.deny_by_inode!(path)
      return unless path.exist?
      return if path.directory?

      target = safe_lstat(path)
      return if target.nil?
      return if target.nlink < 2 # not hardlinked; the name checks already covered it

      denied_inodes.each do |(dev, ino), label|
        next unless target.dev == dev && target.ino == ino

        raise ForbiddenError, "Access denied: #{label} is not accessible through this API"
      end
    end

    # device+inode of every currently-existing denied file, mapped to the
    # relative name used in error messages.
    def self.denied_inodes
      home = Pathname.new(Dir.home)
      home = home.realpath if home.exist?
      map = {}

      DENIED_EXACT.each { |rel| record_inode(map, home + rel, rel) }
      DENIED_DIRS.each do |dir|
        base = home + dir
        next unless base.directory?

        base.find { |child| record_inode(map, child, "#{dir}/#{child.basename}") unless child.directory? }
      end
      map
    end

    def self.safe_lstat(pathname)
      pathname.lstat
    rescue SystemCallError
      nil
    end

    def self.record_inode(map, pathname, label)
      st = safe_lstat(pathname)
      map[[st.dev, st.ino]] = label if st
    end

    # Refuse a recursive delete whose tree contains a denied path. Compares
    # prefixes rather than walking the tree: the denied set is small and fixed,
    # and walking a large home directory on every delete would be slow.
    def self.deny_recursive!(dir)
      home = Pathname.new(Dir.home)
      home = home.realpath if home.exist?
      root = dir.exist? ? dir.realpath : dir

      (DENIED_DIRS + DENIED_EXACT).each do |rel|
        denied = home + rel
        next unless denied.exist?
        next unless path_under?(denied.realpath, root) || denied.realpath == root

        raise ForbiddenError,
              "Access denied: recursive delete would remove #{rel}, which is not accessible through this API"
      end
    end

    # Paths this API refuses to touch even though they sit inside the user's
    # own home and the user could edit them by other means (a shell, the Files
    # app). The point is not privilege — the PUN already runs as the user — but
    # blast radius: an agent driving these tools on injected input should not
    # be able to establish access that outlives the session.
    #
    # Checked against BOTH the requested path and its resolved form, so a
    # symlink into a denied directory does not slip through.
    DENIED_EXACT = [
      '.bashrc', '.bash_profile', '.bash_login', '.bash_logout',
      # Sourced by the stock Debian and Ubuntu .bashrc, so allowing it while
      # denying .bashrc protects the door and leaves the window open.
      '.bash_aliases',
      '.profile', '.login',
      '.zshrc', '.zshenv', '.zprofile', '.zlogin',
      '.cshrc', '.tcshrc', '.kshrc',
      # Read by every git invocation. core.pager and core.sshCommand are
      # arbitrary commands, so a write here is code execution the next time
      # the user runs git.
      '.gitconfig',
      # Credentials in plaintext, read by curl, ftp and git.
      '.netrc',
      # Run at login by MTAs that honour it; "|command" is code execution.
      '.forward',
      # Read by PAM at session start on distributions that enable it.
      '.pam_environment',
      # Grant login to other Kerberos principals or other hosts.
      '.k5login', '.rhosts', '.shosts',
      # Run at logout or at the start of a graphical session.
      '.zlogout', '.logout', '.xsession', '.xinitrc', '.xprofile',
      # Run by every R session.
      '.Rprofile',
      # Credentials in plaintext.
      '.git-credentials', '.pgpass', '.my.cnf'
    ].freeze

    DENIED_DIRS = [
      '.ssh',
      '.config/ondemand',
      '.config/systemd/user',
      # Ahead of the system paths in PATH by default on current Fedora and
      # Ubuntu, so a file written here shadows the real command.
      '.local/bin',
      # Same reasoning as .gitconfig — this is git's XDG location.
      '.config/git',
      # Launched on graphical login under the XDG autostart spec.
      '.config/autostart',
      # On PATH by default on RHEL-family systems, like .local/bin.
      'bin',
      # Sourced by the stock RHEL 9 and Fedora .bashrc, and by systemd and fish
      # at session start.
      '.bashrc.d', '.config/environment.d', '.config/fish',
      # Run when a VNC or Jupyter session starts.
      '.vnc', '.jupyter', '.ipython/profile_default/startup',
      # Credential stores for cloud, cluster and registry clients.
      '.aws', '.azure', '.config/gcloud', '.kube', '.docker', '.gnupg',
      '.config/gh', '.config/rclone'
    ].freeze

    # Denied wherever they appear under $HOME, not at one fixed location.
    DENIED_PATTERNS = [
      # Imported by every Python process the user starts.
      %r{\A\.local/lib/python[^/]+/site-packages/(user|site)customize\.py\z}
    ].freeze

    # A denied name can itself be a symlink: `~/.bashrc -> ~/dots/bashrc` is a
    # common way to keep dotfiles in a repository. The name is refused, but the
    # file it points at is the one the shell reads, so that is refused too.
    def self.deny_aliases!(resolved)
      home = Pathname.new(Dir.home)
      (DENIED_EXACT + DENIED_DIRS).each do |rel|
        denied = home + rel
        next unless denied.symlink?

        target = link_destination(denied)
        next unless resolved == target || path_under?(resolved, target)

        raise ForbiddenError, "Access denied: #{rel} is not accessible through this API"
      end
    end

    def self.link_destination(link)
      link.exist? ? link.realpath : resolved_destination(resolve_link_chain(link))
    rescue SystemCallError
      link
    end

    # Nothing inside a `.git` directory, and no file named `.git`, in any
    # allowed location. Hooks and config there are run or read by every git
    # command in the repository, and a `.git` file can point git at a
    # directory of them anywhere.
    def self.deny_git_internals!(*paths)
      return unless paths.any? { |path| path.each_filename.any? { |part| part.casecmp?('.git') } }

      raise ForbiddenError, 'Access denied: git internals are not accessible through this API'
    end

    def self.deny_sensitive!(requested, resolved)
      deny_git_internals!(requested, resolved)

      # Compare against both the literal and resolved home: on systems where
      # home is reached through a symlink (/var -> /private/var on macOS) the
      # requested path and the resolved one sit under different prefixes, and
      # checking only one of them lets the other slip past.
      raw_home = Pathname.new(Dir.home)
      homes = [raw_home]
      homes << raw_home.realpath if raw_home.exist?

      candidates = [requested, resolved].uniq
      pairs = candidates.product(homes.uniq)

      pairs.each do |candidate, home|
        rel = relative_to_home(candidate, home)
        next unless rel

        # Case-folded, because macOS and Windows filesystems are usually
        # case-insensitive: ~/.SSH/authorized_keys IS ~/.ssh/authorized_keys
        # there, so an exact-case comparison refuses one spelling and permits
        # the other. realpath canonicalises the case once the file exists,
        # which is why this only mattered for a path not yet created — the
        # same window the symlink bypasses used.
        #
        # Folding on a case-sensitive filesystem costs only that a genuinely
        # distinct ~/.SSH is refused too, which is the safe direction.
        folded = rel.downcase
        if DENIED_DIRS.any? { |d| folded == d.downcase || folded.start_with?("#{d.downcase}/") }
          raise ForbiddenError, "Access denied: #{rel} is not accessible through this API"
        end

        if DENIED_EXACT.any? { |name| folded == name.downcase } || DENIED_PATTERNS.any? { |re| re.match?(folded) }
          raise ForbiddenError, "Access denied: #{rel} is not accessible through this API"
        end
      end
    end

    def self.relative_to_home(path, home)
      s = path.to_s
      h = home.to_s
      return nil unless s == h || s.start_with?("#{h}/")

      s[(h.length + 1)..] || ''
    end

    # --- internal helpers ---

    # Where file operations are allowed. A site that sets an allowlist for the
    # Dashboard file browser (OOD_ALLOWLIST_PATH, or allowlist_path in
    # ondemand.d) gets exactly those paths here too, so there is one policy.
    # With no allowlist the Dashboard allows everything; this app is narrower
    # and keeps to the home and temp directories.
    def self.allowed_path_roots
      configured = OodApi::SiteConfig.allowlist_paths
      roots = configured.empty? ? [Pathname.new(Dir.home), Pathname.new('/tmp'), Pathname.new(Dir.tmpdir)] : configured

      roots.map { |root| root.exist? ? root.realpath : root }.uniq
    end

    def self.path_allowed?(path)
      real = Pathname.new(path.to_s).expand_path
      real = real.realpath if real.exist?
      allowed_path_roots.any? { |root| path_under?(real, root) }
    end

    def self.path_under?(child, parent)
      child_str = child.to_s
      parent_str = parent.to_s
      return true if child_str == parent_str

      child_str.start_with?(parent_str) && child_str[parent_str.length] == '/'
    end

    def self.find_real_parent(path)
      path.ascend do |p|
        return p.realpath if p.exist?
      end
      Pathname.new('/')
    end

    # Where a write to `path` would actually land, with every symlinked
    # component resolved — including ones above a target that does not exist.
    #
    # find_real_parent alone is not enough for the deny-list. It stops at the
    # nearest EXISTING ancestor, so a link like /tmp/hd -> $HOME turns a request
    # for /tmp/hd/.ssh/authorized_keys (leaf and .ssh both absent) into the
    # resolved path $HOME — whose path relative to home is "", which matches no
    # denied entry. Neither the requested string nor that answer is under a
    # denied path, so the deny-list passed and the write landed on the real
    # authorized_keys. The leaf is not itself a symlink here, so
    # deny_dangling_symlink! does not fire either.
    #
    # Resolving the deepest existing ancestor and re-appending the components
    # below it reconstructs the true destination, so the deny-list compares
    # against the file that would actually be created.
    def self.resolved_destination(path)
      return path.realpath if path.exist?

      remainder = []
      current = path
      loop do
        parent = current.parent
        remainder.unshift(current.basename)
        break if parent == current # reached the root without finding one

        return remainder.inject(parent.realpath) { |acc, part| acc + part } if parent.exist?

        current = parent
      end
      path
    end

    private_class_method :allowed_path_roots, :path_under?, :find_real_parent,
                         :deny_sensitive!, :relative_to_home,
                         :deny_by_inode!, :denied_inodes, :record_inode, :safe_lstat
  end
end

require_relative 'pinned_files'
