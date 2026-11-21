# frozen_string_literal: true

require 'fileutils'
require_relative 'errors'
require_relative 'pinned_dir'

module Handlers
  # The file operations, done relative to directories that are held open. Used
  # wherever PinnedDir is supported, which is every Linux host. Each operation
  # applies the path policy to where the kernel says the open directory is,
  # then acts on an entry inside it by name, so nothing is resolved twice.
  #
  # Callers have already normalised the path and map Errno errors to responses.
  module PinnedFiles
    OPEN_SAFELY = File::NONBLOCK | File::NOFOLLOW

    # @return [String] up to `limit` bytes of the file
    def self.read(path, limit:, refuse_larger:)
      with_target(path) do |dir, name, _real, stat|
        raise Errno::ENOENT if stat.nil?
        raise ValidationError, 'Cannot read directory contents' if stat.directory?
        # Checked before the open as well as after: opening some devices has
        # effects of its own.
        raise ValidationError, 'Not a regular file' unless stat.file?

        File.open(dir.entry(name), File::RDONLY | OPEN_SAFELY) do |file|
          raise ValidationError, 'Not a regular file' unless file.stat.file?

          Files.deny_inode!(file.stat)
          raise PayloadTooLargeError, "File too large (max #{limit} bytes)" if refuse_larger && file.stat.size > limit

          file.read(limit) || ''
        end
      end
    end

    def self.write(path, content, append:)
      with_target(path, create_parents: true) do |dir, name, _real, stat|
        raise ValidationError, 'Cannot write to directory' if stat&.directory?
        raise ValidationError, 'Not a regular file' if stat && !stat.file?

        flags = File::WRONLY | File::CREAT | OPEN_SAFELY | (append ? File::APPEND : 0)
        File.open(dir.entry(name), flags) do |file|
          raise ValidationError, 'Not a regular file' unless file.stat.file?

          Files.deny_inode!(file.stat)
          file.truncate(0) unless append
          file.write(content)
        end
      end
    end

    # @return [File::Stat] the file itself, reached through the user's own
    #   symlinks and looked at inside the pinned directory
    def self.stat(path)
      with_target(path) do |_dir, _name, _real, stat|
        raise Errno::ENOENT if stat.nil?

        stat
      end
    end

    def self.mkdir(path)
      pin(path, create_parents: true) do |dir, name, _real|
        raise ValidationError, 'Path already exists' if dir.lstat(name)

        Dir.mkdir(dir.entry(name))
      end
    end

    # Follows the user's own symlinks, as read and write do. The times are set
    # on the entry by name without following a link, so a file the user owns
    # but cannot open is still touched, and an entry swapped for a symlink
    # after it was looked at changes nothing but the link.
    def self.touch(path)
      with_target(path) do |dir, name, _real, stat|
        next File.open(dir.entry(name), File::WRONLY | File::CREAT | OPEN_SAFELY, &:close) if stat.nil?
        raise ValidationError, 'Not a regular file' unless stat.file? || stat.directory?

        Files.deny_inode!(stat) if stat.file?
        now = Time.now
        File.lutime(now, now, dir.entry(name))
      end
    end

    def self.delete(path, recursive:)
      pin(path) do |dir, name, real|
        stat = dir.lstat(name)
        raise Errno::ENOENT if stat.nil?
        next File.unlink(dir.entry(name)) unless stat.directory?
        next remove_tree(dir, name, real) if recursive
        raise ValidationError, 'Directory not empty' unless Dir.empty?(dir.entry(name))

        Dir.rmdir(dir.entry(name))
      end
    end

    def self.remove_tree(dir, name, real)
      Files.deny_recursive!(real)
      remove_directory(dir, name)
    end

    # Removes a directory and everything in it, holding each level open and
    # never following a symlink. Walking the tree by name would let whoever
    # owns part of it swap a subdirectory for a symlink mid-walk and have the
    # contents of the link's target deleted. Here a swapped entry makes the
    # open or the unlink fail, and the removal stops.
    def self.remove_directory(parent, name)
      directory = open_for_removal(parent, name)
      return Dir.rmdir(parent.entry(name)) unless directory

      Dir.children(directory.entry('.')).each do |child|
        next remove_directory(directory, child) if directory.lstat(child)&.directory?

        File.unlink(directory.entry(child))
      end
      Dir.rmdir(parent.entry(name))
    ensure
      directory&.close
    end

    # A directory the user cannot read can still be removed if it is empty,
    # so that is left to rmdir to decide.
    #
    # @return [PinnedDir, nil] nil when the directory cannot be opened
    def self.open_for_removal(parent, name)
      parent.descend(name)
    rescue Errno::EACCES
      nil
    end

    # @return [Array<Array(String, File::Stat)>] each name in the directory
    #   with the stat of the entry itself, not of what a symlink points at
    def self.children(path)
      dir = PinnedDir.open(path)
      Files.validate_real!(dir.real)
      Dir.children(dir.entry('.')).filter_map do |name|
        stat = dir.lstat(name)
        [name, stat, (File.readlink(dir.entry(name)) if stat.symlink?)] if stat
      rescue SystemCallError
        nil
      end
    ensure
      dir&.close
    end

    # Yields the open parent directory of `path`, the entry's name, and where
    # the entry really is. Missing parents are created one level at a time
    # inside the pinned directory, so none can be redirected while it happens.
    def self.pin(path, create_parents: false)
      existing, missing = split_existing(path.parent)
      raise Errno::ENOENT unless missing.empty? || create_parents

      dir = PinnedDir.open(existing)
      Files.validate_real!(dir.real)
      missing.each do |part|
        # Checked before it is created, so a refused request leaves no
        # directory behind.
        Files.validate_real!(dir.real + part)
        deeper = dir.descend(part, create: true)
        dir.close
        dir = deeper
      end

      real = dir.real + path.basename.to_s
      Files.validate_real!(real)
      yield dir, path.basename.to_s, real
    ensure
      dir&.close
    end

    # @return [Array(Pathname, Array<String>)] the deepest directory that
    #   exists, and the names below it that do not
    def self.split_existing(directory)
      missing = []
      until File.directory?(directory.to_s)
        missing.unshift(directory.basename.to_s)
        directory = directory.parent
      end
      [directory, missing]
    end

    # Like `pin`, but when the entry is a symlink it follows the link itself,
    # pinning and checking each hop, and also yields the entry's lstat.
    def self.with_target(path, create_parents: false, &block)
      Files::MAX_SYMLINK_HOPS.times do
        link = nil
        result = pin(path, create_parents: create_parents) do |dir, name, real|
          stat = dir.lstat(name)
          next link = link_target(dir, name, real, stat) if stat&.symlink?

          block.call(dir, name, real, stat)
        end
        return result unless link

        path = link
      end
      raise ForbiddenError, 'Access denied: symbolic link could not be resolved'
    end

    # Where a symlink points, if it may be followed. Only the user's own
    # links and root's are. The kernel refuses to follow another user's link
    # in a sticky directory such as /tmp, and following it here by hand would
    # sidestep that: someone else's link could steer a write onto one of the
    # user's own files.
    def self.link_target(dir, name, real, stat)
      unless [Process.euid, 0].include?(stat.uid)
        raise ForbiddenError, 'Access denied: symbolic link belongs to another user'
      end

      Pathname.new(File.expand_path(File.readlink(dir.entry(name)), real.parent.to_s))
    end

    private_class_method :pin, :split_existing, :with_target, :link_target, :remove_tree, :remove_directory,
                         :open_for_removal
  end
end
