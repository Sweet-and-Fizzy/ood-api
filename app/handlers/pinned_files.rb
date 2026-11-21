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

          file.truncate(0) unless append
          file.write(content)
        end
      end
    end

    def self.mkdir(path)
      pin(path, create_parents: true) do |dir, name, _real|
        raise ValidationError, 'Path already exists' if dir.lstat(name)

        Dir.mkdir(dir.entry(name))
      end
    end

    def self.touch(path)
      pin(path) do |dir, name, _real|
        now = Time.now
        next touch_directory(dir, name, now) if dir.lstat(name)&.directory?

        File.open(dir.entry(name), File::WRONLY | File::CREAT | OPEN_SAFELY) do |file|
          raise ValidationError, 'Not a regular file' unless file.stat.file?

          File.utime(now, now, "#{PinnedDir::PROC_FD}/#{file.fileno}")
        end
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

    # Opened without following a symlink, so the directory whose times change
    # is the one that was looked at.
    def self.touch_directory(dir, name, now)
      directory = dir.descend(name)
      File.utime(now, now, directory.entry('.'))
    ensure
      directory&.close
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
      directory = parent.descend(name)
      Dir.children(directory.entry('.')).each do |child|
        next remove_directory(directory, child) if directory.lstat(child)&.directory?

        File.unlink(directory.entry(child))
      end
      Dir.rmdir(parent.entry(name))
    ensure
      directory&.close
    end

    # @return [Array<String>] the names in the directory
    def self.children(path)
      dir = PinnedDir.open(path)
      Files.validate_real!(dir.real)
      Dir.children(dir.entry('.'))
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
                         :touch_directory
  end
end
