# frozen_string_literal: true

require 'pathname'
require_relative 'errors'

module Handlers
  module Context
    CONTEXT_PATH = ENV.fetch('OOD_API_CONTEXT_PATH', '/etc/ood/config/agents.d')

    # Per-file cap. Each fragment is site policy, not data, so anything large
    # is a mistake. Without a cap a single big file balloons the worker's heap
    # several times over — the raw string, the stripped copy, the join, and the
    # JSON encoding all coexist — inside the user's own PUN.
    MAX_FILE_BYTES = ENV.fetch('OOD_API_MAX_CONTEXT_BYTES', 256 * 1024).to_i

    def self.read
      dir = Pathname.new(CONTEXT_PATH)
      return '' unless dir.directory?

      files = dir.glob('*.md').sort
      return '' if files.empty?

      files.filter_map { |f| fragment(f) }.join("\n\n")
    end

    # Returns the rendered fragment, or nil if the file should be skipped.
    #
    # One unreadable file must not take down the whole resource: a root-owned
    # 0600 policy fragment or a stale symlink would otherwise raise EACCES or
    # ENOENT out of the route and return a bare 500. Agents are told to read
    # this before acting, so failing open with the remaining fragments beats
    # failing closed with none.
    def self.fragment(path)
      body = read_capped(path)
      return nil if body.nil?

      "<!-- Source: #{path.basename} -->\n#{neutralize_markers(body)}"
    end

    def self.read_capped(path)
      size = path.size
      return "(omitted: #{path.basename} is #{size} bytes, over the #{MAX_FILE_BYTES}-byte limit)" if
        size > MAX_FILE_BYTES

      path.read.strip
    rescue SystemCallError, IOError
      nil
    end

    # The `<!-- Source: … -->` line tells an agent which fragment it is reading.
    # A file that prints one of its own could impersonate a more authoritative
    # fragment, so defang the delimiter in file bodies.
    def self.neutralize_markers(body)
      body.gsub(/<!--(\s*Source:)/i, '<!-\\-\1')
    end

    private_class_method :fragment, :read_capped, :neutralize_markers
  end
end
