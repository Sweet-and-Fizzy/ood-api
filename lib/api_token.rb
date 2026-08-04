# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'fileutils'
# Time#iso8601 lives in the stdlib `time` library, not in core. This file only
# worked because Rack happened to load it first; requiring it directly keeps
# the class usable on its own.
require 'time'

module OodApi
  # Manages API tokens stored in user's home directory
  # Tokens are stored at ~/.config/ondemand/tokens.json
  # Compatible with OOD Dashboard's ApiToken model
  class ApiToken
    TOKENS_DIR = File.expand_path('~/.config/ondemand')
    TOKENS_FILE = File.join(TOKENS_DIR, 'tokens.json')

    # Locking uses a sidecar file rather than tokens.json itself. flock(2) is
    # held against an inode, and save_tokens replaces the data file by rename,
    # so a lock taken on tokens.json guards an inode that the next writer
    # unlinks — two processes end up "holding" the lock on different inodes and
    # exclude nobody. The lock file is never renamed over, so it stays stable.
    LOCK_FILE = File.join(TOKENS_DIR, '.tokens.json.lock')

    attr_reader :id, :name, :token, :created_at, :last_used_at

    def initialize(attrs = {})
      @id = attrs[:id] || attrs['id']
      @name = attrs[:name] || attrs['name']
      @token = attrs[:token] || attrs['token']
      @created_at = attrs[:created_at] || attrs['created_at']
      @last_used_at = attrs[:last_used_at] || attrs['last_used_at']
    end

    class << self
      # Find a token by its plain text value using timing-safe comparison
      def find_by_token(plain_token)
        return nil if plain_token.nil? || plain_token.empty?

        load_tokens.each do |attrs|
          # Only a String is a credential. `to_s` on its own would turn an
          # unquoted `"token": 123456` in a hand-edited file into a working
          # token spelled "123456", and installation docs invite hand-editing.
          stored = attrs[:token]
          next unless stored.is_a?(String)

          return new(attrs) if tokens_match?(stored, plain_token.to_s)
        end
        nil
      end

      # List all tokens for the current user
      def all
        load_tokens.map { |attrs| new(attrs) }
      end

      # Create a new token, returns [ApiToken, plain_token]
      def create(name:)
        plain_token = SecureRandom.hex(32)
        token_attrs = {
          id:         SecureRandom.uuid,
          name:       name,
          token:      plain_token,
          created_at: Time.now.iso8601
        }

        with_lock do
          tokens = load_tokens
          tokens << token_attrs
          save_tokens(tokens)
        end

        [new(token_attrs), plain_token]
      end

      # Delete a token by ID
      def destroy(id)
        with_lock do
          tokens = load_tokens.reject { |t| t[:id] == id }
          save_tokens(tokens)
        end
      end

      # Update last_used_at for a token
      # Records last-used bookkeeping. Deliberately never raises: the caller
      # has already authenticated, and a read-only or full token store should
      # not turn a valid request into a 500.
      def touch(token)
        with_lock do
          tokens = load_tokens
          token_data = tokens.find { |t| t[:id] == token.id }
          return unless token_data

          token_data[:last_used_at] = Time.now.iso8601
          save_tokens(tokens)
        end
      rescue SystemCallError, IOError => e
        warn "ood_api_audit op=token_touch status=error error=#{e.class}"
        nil
      end

      private

      # Serialises read-modify-write across processes. The Dashboard plugin
      # writes the same file, so the lock has to be visible to a separate
      # application, not just to threads here.
      #
      # Without this, a revoke racing the per-request touch is a lost update:
      # both load the full array, both write their own copy back, and the
      # revoked token is resurrected while the UI reports success.
      def with_lock
        FileUtils.mkdir_p(TOKENS_DIR)
        File.open(LOCK_FILE, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def load_tokens
        return [] unless File.exist?(TOKENS_FILE)

        # Explicit encoding: the PUN's locale may be US-ASCII, and a token
        # name is free text a user typed into the Dashboard.
        parsed = JSON.parse(File.read(TOKENS_FILE, encoding: 'UTF-8'), symbolize_names: true)

        # Valid JSON of the wrong shape is a distinct case from unparseable
        # JSON, and installation docs invite operators to write this file by
        # hand. A bare object or an array of strings parses fine and then
        # raises from the callers that index each entry, turning every
        # authenticated request into a 500.
        return parsed if parsed.is_a?(Array) && parsed.all?(Hash)

        warn 'ood_api_audit op=token_load status=corrupt error=unexpected_shape'
        []
      rescue JSON::ParserError => e
        # Failing open to [] means "you have no tokens", which 401s the user
        # rather than erroring. Without this line there is no trace at all when
        # someone reports that their tokens vanished.
        warn "ood_api_audit op=token_load status=corrupt error=#{e.class}"
        []
      end

      # Write via a temp file and rename, so a concurrent reader never sees a
      # truncated or partial file. `touch` calls this on every authenticated
      # request, and load_tokens rescues JSON::ParserError to [] — so a torn
      # read would silently invalidate every token and 401 the user. rename(2)
      # is atomic within a filesystem, which the temp file guarantees by
      # living in TOKENS_DIR.
      def save_tokens(tokens)
        FileUtils.mkdir_p(TOKENS_DIR)
        tmp = File.join(TOKENS_DIR, ".tokens.json.#{Process.pid}.#{SecureRandom.hex(4)}")
        begin
          # Create with 0600 from the start so the token file is never briefly
          # world-readable between creation and chmod.
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
            f.write(JSON.pretty_generate(tokens))
            f.flush
            f.fsync
          end
          File.rename(tmp, TOKENS_FILE)
        ensure
          FileUtils.rm_f(tmp)
        end
        # Narrows any pre-existing file that predates this change.
        File.chmod(0o600, TOKENS_FILE)
      end

      # Timing-safe string comparison to prevent timing attacks
      def tokens_match?(left, right)
        return false unless left.bytesize == right.bytesize

        left_bytes = left.unpack('C*')
        result = 0
        right.each_byte { |byte| result |= byte ^ left_bytes.shift }
        result.zero?
      end
    end

    def to_h
      {
        id:           id,
        name:         name,
        token:        token,
        created_at:   created_at,
        last_used_at: last_used_at
      }
    end
  end
end
