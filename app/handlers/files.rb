# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'etc'
require 'tmpdir'
require_relative 'errors'

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

      if p.directory?
        p.children.select(&:readable?).sort_by { |c| [c.directory? ? 0 : 1, c.basename.to_s.downcase] }
      else
        p
      end
    rescue Errno::ENOENT
      raise NotFoundError, 'Path not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
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
      readable_file!(p)

      effective_limit = max_size ? [max_size, MAX_FILE_READ].min : MAX_FILE_READ
      if !max_size && (p.size > effective_limit)
        raise PayloadTooLargeError, "File too large (max #{effective_limit} bytes)"
      end

      max_size ? File.read(p.to_s, effective_limit) : p.read
    rescue Errno::ENOENT
      raise NotFoundError, 'File not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
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

      p.parent.mkpath unless p.parent.exist?
      if append
        File.open(p, 'a') { |f| f.write(content) }
      else
        p.write(content)
      end
      p
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue *OUT_OF_SPACE_ERRORS => e
      raise StorageError, out_of_space_message(e)
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    def self.mkdir(path:)
      p = normalize_path(path)
      validate_path!(p)
      raise ValidationError, 'Path already exists' if p.exist?

      p.mkpath
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

      FileUtils.touch(p)
      p
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue *OUT_OF_SPACE_ERRORS => e
      raise StorageError, out_of_space_message(e)
    rescue *BAD_PATH_ERRORS => e
      raise ValidationError, e.message.sub(/ @ .*/, '')
    end

    def self.delete(path:, recursive: false)
      p = normalize_path(path)
      validate_path!(p)
      raise NotFoundError, 'Path not found' unless p.exist?

      if p.directory?
        if recursive
          # validate_path! only checked the target. Recursion would sweep any
          # denied path beneath it — deleting ~/.config takes ~/.config/ondemand
          # (the token store) with it, and deleting ~ takes ~/.ssh.
          deny_recursive!(p)
          FileUtils.rm_rf(p)
        else
          raise ValidationError, 'Directory not empty' unless p.children.empty?

          p.rmdir
        end
      else
        p.delete
      end

      { path: p.to_s, deleted: true }
    rescue Errno::ENOENT
      raise NotFoundError, 'Path not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    rescue Errno::ENOTEMPTY
      raise ValidationError, 'Directory not empty'
    end

    # --- exposed helpers (used by routes for param handling) ---

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
      deny_dangling_symlink!(path)
      deny_by_inode!(path)
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
      '.pam_environment'
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
      '.config/autostart'
    ].freeze

    def self.deny_sensitive!(requested, resolved)
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

        if DENIED_EXACT.any? { |name| folded == name.downcase }
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

    def self.allowed_path_roots
      roots = []
      home = Pathname.new(Dir.home)
      roots << (home.exist? ? home.realpath : home)

      ['/tmp', Dir.tmpdir].each do |tmp|
        tmp_path = Pathname.new(tmp)
        roots << (tmp_path.exist? ? tmp_path.realpath : tmp_path)
      end

      roots.uniq
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
                         :deny_by_inode!, :denied_inodes, :record_inode, :safe_lstat,
                         :deny_recursive!
  end
end
