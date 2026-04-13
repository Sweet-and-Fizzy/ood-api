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

    def self.read(path:, max_size: nil)
      p = normalize_path(path)
      validate_path!(p)
      raise NotFoundError, 'File not found' unless p.exist?
      raise ValidationError, 'Cannot read directory contents' if p.directory?
      raise ForbiddenError, 'Permission denied' unless p.readable?

      effective_limit = max_size ? [max_size, MAX_FILE_READ].min : MAX_FILE_READ
      unless max_size
        raise PayloadTooLargeError, "File too large (max #{effective_limit} bytes)" if p.size > effective_limit
      end

      max_size ? File.read(p.to_s, effective_limit) : p.read
    rescue Errno::ENOENT
      raise NotFoundError, 'File not found'
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
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
    rescue Errno::ENOSPC
      raise StorageError, 'No space left on device'
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
    end

    def self.touch(path:)
      p = normalize_path(path)
      validate_path!(p)

      FileUtils.touch(p)
      p
    rescue Errno::EACCES
      raise ForbiddenError, 'Permission denied'
    end

    def self.delete(path:, recursive: false)
      p = normalize_path(path)
      validate_path!(p)
      raise NotFoundError, 'Path not found' unless p.exist?

      if p.directory?
        if recursive
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

    def self.normalize_path(path_str)
      expanded = File.expand_path(path_str.to_s)
      Pathname.new(expanded)
    end

    def self.validate_path!(path)
      allowed_roots = allowed_path_roots
      real_path = path.exist? ? path.realpath : find_real_parent(path)
      allowed = allowed_roots.any? { |root| path_under?(real_path, root) }
      raise ForbiddenError, 'Access denied: path not in allowed directories' unless allowed
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

    private_class_method :allowed_path_roots, :path_under?, :find_real_parent
  end
end
