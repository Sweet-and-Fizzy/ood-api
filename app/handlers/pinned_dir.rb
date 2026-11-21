# frozen_string_literal: true

require 'pathname'

module Handlers
  # A directory held open, so its entries can be worked on by name.
  #
  # A path is checked as a string and then opened, and the open resolves the
  # string again. Anyone who can write to a directory along the way can swap a
  # component for a symlink between the two, so the open lands somewhere the
  # check never saw. Holding the directory open removes the second
  # resolution: the kernel reports where the open directory really is, the
  # policy is applied to that, and files are then opened relative to it.
  #
  # This relies on /proc/self/fd, which Linux provides. On a system that
  # never has it, `supported?` is false and callers fall back to checking the
  # path before and after. On a Linux host where it is missing, file
  # operations are refused; see Handlers::Files.access_mode.
  class PinnedDir
    PROC_FD = '/proc/self/fd'

    def self.supported?
      return @supported unless @supported.nil?

      @supported = File.symlink?("#{PROC_FD}/0")
    rescue SystemCallError
      @supported = false
    end

    # @return [Boolean] whether this platform normally provides /proc/self/fd
    def self.expected?
      RUBY_PLATFORM.include?('linux')
    end

    # @param path [Pathname, String] an existing directory
    def self.open(path)
      new(open_directory(path.to_s))
    end

    # File::DIRECTORY (O_DIRECTORY) is missing before Ruby 3.4 and its value
    # varies by CPU, so the type is checked on the open descriptor instead.
    # Non-blocking, so a FIFO in the same position cannot hold the open.
    #
    # The descriptor is the point of this class, so it is returned open and
    # closed by `close`, not by a block.
    def self.open_directory(path, flags = 0)
      handle = File.open(path, File::RDONLY | File::NONBLOCK | flags) # rubocop:disable Style/FileOpen
      return handle if handle.stat.directory?

      handle.close
      raise Errno::ENOTDIR, path
    end

    def initialize(handle)
      @io = handle
    end

    # @return [Pathname] where the open directory is, with no symlinks in it
    def real
      Pathname.new(File.readlink("#{PROC_FD}/#{@io.fileno}"))
    end

    # @return [String] a path to `name` inside this directory that cannot be
    #   redirected by changing any directory above it
    def entry(name)
      "#{PROC_FD}/#{@io.fileno}/#{name}"
    end

    # @return [File::Stat, nil] the entry itself, not what a symlink points at
    def lstat(name)
      File.lstat(entry(name))
    rescue Errno::ENOENT
      nil
    end

    # Opens the subdirectory `name`, creating it first when asked. A symlink
    # in that position is refused rather than followed.
    #
    # @return [PinnedDir]
    def descend(name, create: false)
      if create
        begin
          Dir.mkdir(entry(name))
        rescue Errno::EEXIST
          nil
        end
      end
      self.class.new(self.class.open_directory(entry(name), File::NOFOLLOW))
    end

    def close
      @io.close unless @io.closed?
    end
  end
end
