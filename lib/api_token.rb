# frozen_string_literal: true

require_relative 'log'

require 'json'
require 'digest'
require 'securerandom'
require 'fileutils'
# Time#iso8601 lives in the stdlib `time` library, not in core. This file only
# worked because Rack happened to load it first; requiring it directly keeps
# the class usable on its own.
require 'time'
require_relative 'token_policy'

module OodApi
  # The user's API tokens, stored at ~/.config/ondemand/tokens.json. The
  # Dashboard token page uses this class too, from the Dashboard's process.
  class ApiToken
    TOKENS_DIR = File.expand_path('~/.config/ondemand')
    TOKENS_FILE = File.join(TOKENS_DIR, 'tokens.json')

    # Locking uses a sidecar file rather than tokens.json itself. flock(2) is
    # held against an inode, and save_tokens replaces the data file by rename,
    # so a lock taken on tokens.json guards an inode that the next writer
    # unlinks — two processes end up "holding" the lock on different inodes and
    # exclude nobody. The lock file is never renamed over, so it stays stable.
    LOCK_FILE = File.join(TOKENS_DIR, '.tokens.json.lock')

    # last_used_at is bookkeeping for the token page, not a security control.
    # Writing it on every request means an fsync to an NFS home per API call,
    # so it is refreshed at most this often.
    TOUCH_INTERVAL = 300

    attr_reader :id, :name, :token_digest, :created_at, :last_used_at, :expires_at

    def initialize(attrs = {})
      @id = attrs[:id] || attrs['id']
      @name = attrs[:name] || attrs['name']
      @token_digest = attrs[:token_digest] || attrs['token_digest']
      @created_at = attrs[:created_at] || attrs['created_at']
      @last_used_at = attrs[:last_used_at] || attrs['last_used_at']
      @expires_at = attrs.fetch(:expires_at) { attrs['expires_at'] }
    end

    # A token with no expiry recorded has not expired: either the site allows
    # tokens that never expire, or the entry predates expiry and is given one
    # the next time the store is written.
    def expired?(now = Time.now)
      TokenPolicy.expired?(expires_at, now)
    end

    class << self
      # Only a SHA-256 digest of each token is stored. Tokens are 256 bits of
      # SecureRandom, so an unsalted digest cannot be brute-forced, and a copy
      # of tokens.json (a backup, a snapshot, a job that reads it) no longer
      # yields a working credential.
      def digest(plain_token)
        Digest::SHA256.hexdigest(plain_token.to_s)
      end

      # Find a token by its plain text value using timing-safe comparison
      def find_by_token(plain_token)
        return nil if plain_token.nil? || plain_token.empty?

        presented = digest(plain_token)
        load_tokens.each do |attrs|
          stored = stored_digest(attrs)
          next unless stored

          return new(attrs.merge(token_digest: stored)) if tokens_match?(stored, presented)
        end
        nil
      end

      # List all tokens for the current user
      def all
        load_tokens.map { |attrs| new(attrs) }
      end

      # Create a new token, returns [ApiToken, plain_token]
      def create(name:, expires_at: TokenPolicy.default_expiry)
        plain_token = SecureRandom.hex(32)
        token_attrs = {
          id:           SecureRandom.uuid,
          name:         name,
          token_digest: digest(plain_token),
          created_at:   Time.now.iso8601,
          expires_at:   expires_at
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

      # Records last-used bookkeeping. Deliberately never raises: the caller
      # has already authenticated, and a read-only or full token store should
      # not turn a valid request into a 500.
      def touch(token)
        with_lock do
          tokens = load_tokens
          token_data = tokens.find { |t| t[:id] == token.id }
          return unless token_data
          # An entry that still needs hashing or an expiry is always
          # rewritten, so that happens on its first use rather than whenever
          # the interval next lapses.
          return if recently_touched?(token_data) && !needs_rewrite?(token_data)

          token_data[:last_used_at] = Time.now.iso8601
          save_tokens(tokens)
        end
      rescue SystemCallError, IOError => e
        OodApi::Log.line "op=token_touch status=error error=#{e.class}"
        nil
      end

      private

      # The digest for a stored entry, or nil when it holds no credential.
      #
      # Entries written before hashing carry a plaintext `token`, and the
      # installation guide used to tell operators to write one by hand. Those
      # still authenticate; save_tokens replaces the plaintext with its digest
      # the next time the file is written.
      #
      # Only a String is a credential. `to_s` on its own would turn an unquoted
      # `"token": 123456` in a hand-edited file into a working token.
      def stored_digest(attrs)
        hashed = attrs[:token_digest]
        return hashed if hashed.is_a?(String) && hashed.match?(/\A\h{64}\z/)

        legacy = attrs[:token]
        legacy.is_a?(String) && !legacy.empty? ? digest(legacy) : nil
      end

      # Brings a stored entry up to date on its way back to disk: a plaintext
      # token becomes its digest, and an entry with no expiry gets one.
      def harden(attrs)
        attrs = attrs.merge(expires_at: TokenPolicy.default_expiry) if TokenPolicy.needs_expiry?(attrs)
        return attrs unless attrs.key?(:token)

        hashed = stored_digest(attrs)
        rest = attrs.except(:token)
        hashed ? rest.merge(token_digest: hashed) : rest
      end

      def needs_rewrite?(attrs)
        attrs.key?(:token) || TokenPolicy.needs_expiry?(attrs)
      end

      def recently_touched?(token_data)
        last = Time.iso8601(token_data[:last_used_at].to_s)
        (Time.now - last).between?(0, TOUCH_INTERVAL)
      rescue ArgumentError
        false
      end

      # Serialises read-modify-write across processes. The Dashboard token
      # page runs this same code in another process, so the lock has to be
      # visible across processes, not just to threads here.
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

        OodApi::Log.line 'op=token_load status=corrupt error=unexpected_shape'
        []
      rescue JSON::ParserError => e
        # Failing open to [] means "you have no tokens", which 401s the user
        # rather than erroring. Without this line there is no trace at all when
        # someone reports that their tokens vanished.
        OodApi::Log.line "op=token_load status=corrupt error=#{e.class}"
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
            f.write(JSON.pretty_generate(tokens.map { |t| harden(t) }))
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
        token_digest: token_digest,
        created_at:   created_at,
        last_used_at: last_used_at,
        expires_at:   expires_at
      }
    end
  end
end
