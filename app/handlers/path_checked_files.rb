# frozen_string_literal: true

require 'fileutils'
require_relative 'errors'

module Handlers
  # The file operations for systems without /proc/self/fd, which means
  # development on macOS. A path is resolved and checked, opened, and then
  # checked again against the open file. That narrows the window in which a
  # component can be swapped for a symlink without closing it, so this is not
  # used on Linux; see PinnedFiles and Files.access_mode.
  #
  # Callers have already normalised and validated the path, and map Errno
  # errors to responses.
  module PathCheckedFiles
    # @return [String] up to `limit` bytes of the file
    def self.read(path, limit:, refuse_larger:)
      readable_file!(path)
      expected = checked_destination(path)
      File.open(path.to_s, File::RDONLY | File::NONBLOCK) do |file|
        verify_open_file!(file, path, expected)
        raise PayloadTooLargeError, "File too large (max #{limit} bytes)" if refuse_larger && file.stat.size > limit

        file.read(limit) || ''
      end
    end

    def self.readable_file!(path)
      raise Errno::ENOENT unless path.exist?
      raise ValidationError, 'Cannot read directory contents' if path.directory?
      # Regular files only. Reading a FIFO blocks until someone writes, which
      # holds the worker, and a device such as /dev/zero never ends.
      raise ValidationError, 'Not a regular file' unless path.file?
      raise Errno::EACCES unless path.readable?
    end

    def self.write(path, content, append:)
      raise ValidationError, 'Cannot write to directory' if path.directory?

      path.parent.mkpath unless path.parent.exist?
      expected = checked_destination(path)
      # No O_TRUNC: nothing is destroyed until the open file has been checked.
      flags = File::WRONLY | File::CREAT | File::NONBLOCK | (append ? File::APPEND : 0)
      File.open(path.to_s, flags) do |file|
        verify_open_file!(file, path, expected)
        file.truncate(0) unless append
        file.write(content)
      end
    end

    def self.mkdir(path)
      raise ValidationError, 'Path already exists' if path.exist?

      path.mkpath
    end

    def self.stat(path)
      path.stat
    end

    def self.touch(path)
      FileUtils.touch(path)
    end

    def self.delete(path, recursive:)
      # A symlink is removed as a link, whatever it points at.
      return path.delete if path.symlink? || !path.directory?
      return remove_tree(path) if recursive
      raise ValidationError, 'Directory not empty' unless path.children.empty?

      path.rmdir
    end

    def self.remove_tree(path)
      Files.deny_recursive!(path)
      FileUtils.rm_rf(path)
    end

    # @return [Array<Array(String, File::Stat)>] each name in the directory
    #   with the stat of the entry itself
    def self.children(path)
      path.children.filter_map do |child|
        stat = child.lstat
        [child.basename.to_s, stat, (child.readlink.to_s if stat.symlink?)]
      rescue Errno::ENOENT
        nil
      end
    end

    # Resolves the path and applies the policy to the result, so the
    # destination the open is later compared against was itself checked.
    def self.checked_destination(path)
      expected = expected_destination(path)
      Files.validate_real!(expected)
      expected
    end

    # Where an open of `path` should land, worked out before the open.
    def self.expected_destination(path)
      return path.realpath if path.exist?

      target = path.symlink? ? Files.resolve_link_chain(path) : path
      target.parent.realpath.join(target.basename)
    end

    # The open file must be a regular file, the path must still resolve to
    # where it did when it was checked, and the descriptor must be that file.
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

    private_class_method :readable_file!, :remove_tree, :checked_destination, :verify_open_file!
  end
end
