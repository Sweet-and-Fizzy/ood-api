# frozen_string_literal: true

# Time.parse and Time#iso8601 live in the stdlib `time` library, not in core.
# Rails loads it, so this file works without the require — but ood-api's twin
# (lib/api_token.rb) broke exactly this way when it was loaded outside Rack.
# Requiring it directly keeps the two copies honest about their dependencies.
require 'time'
require 'digest'

# Represents an API token for authenticating programmatic access to OOD.
# Tokens are stored in a user-local JSON file.
#
# Token storage is user-specific: ~/.config/ondemand/tokens.json
# In OOD's per-user PUN architecture, this is the authenticated user's home directory.
class ApiToken
  include ActiveModel::Model

  # No expiry field here on purpose. An earlier version carried `expires_at`
  # and an `active?` helper, but nothing enforced either — ood-api's
  # AppAuth.authenticate accepts any token whose value matches. Since
  # docs/installation.md tells operators they may hand-write tokens.json, a
  # visible-but-unenforced expiry field invites someone to add an expiry and
  # believe the credential dies on its own. Revocation is the real control.
  attr_reader :id, :name, :token_digest, :created_at, :last_used_at

  TOKEN_DIR = Pathname.new('~/.config/ondemand').expand_path
  TOKEN_FILE = TOKEN_DIR.join('tokens.json')

  # Locking uses a sidecar file rather than tokens.json itself. flock(2) is
  # held against an inode, and save_tokens replaces the data file by rename,
  # so a lock taken on tokens.json guards an inode that the next writer
  # unlinks. The lock file is never renamed over, so it stays stable.
  #
  # This file is also written by ood-api's OodApi::ApiToken (lib/api_token.rb)
  # from a different process. Both must agree on this path or the lock is
  # useless — keep the two in sync.
  LOCK_FILE = TOKEN_DIR.join('.tokens.json.lock')

  class << self
    def all
      load_tokens.map { |attrs| new(attrs) }
    end

    def find(id)
      attrs = load_tokens.find { |t| t[:id] == id }
      attrs ? new(attrs) : nil
    end

    # Only a SHA-256 digest is stored, matching lib/api_token.rb. Tokens are
    # 256 bits of SecureRandom, so an unsalted digest cannot be brute-forced.
    def digest(plain_token)
      Digest::SHA256.hexdigest(plain_token.to_s)
    end

    # Returns [ApiToken, plain_token]. The plaintext exists only in this return
    # value, for the one page render that shows it to the user.
    def generate(name:)
      plain_token = SecureRandom.hex(32)
      token_attrs = {
        id:           SecureRandom.uuid,
        name:         name,
        token_digest: digest(plain_token),
        created_at:   Time.current.iso8601
      }

      with_lock do
        tokens = load_tokens
        tokens << token_attrs
        save_tokens(tokens)
      end

      [new(token_attrs), plain_token]
    end

    # Serialises read-modify-write across processes. ood-api writes this same
    # file from its own PUN process on every authenticated request, so the
    # lock has to be visible to a separate application, not just to Rails.
    def with_lock
      TOKEN_DIR.mkpath unless TOKEN_DIR.exist?
      LOCK_FILE.open(File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def load_tokens
      return [] unless TOKEN_FILE.exist?

      # Explicit encoding, matching lib/api_token.rb: without one Ruby uses the
      # locale's, and a token name is free text a user typed.
      parsed = JSON.parse(TOKEN_FILE.read(encoding: 'UTF-8'), symbolize_names: true)

      # Shape guard, matching lib/api_token.rb. Valid JSON that is not an array
      # of hashes parses and then raises from every caller that indexes an
      # entry.
      return parsed if parsed.is_a?(Array) && parsed.all?(Hash)

      Rails.logger.error('API tokens file is not an array of objects; ignoring')
      []
    rescue JSON::ParserError => e
      Rails.logger.error("Failed to parse API tokens file: #{e.message}")
      []
    end

    # Write via a temp file and rename, so a concurrent reader never sees a
    # truncated file. ood-api calls its own save on every authenticated
    # request, and both readers rescue JSON::ParserError to [] — so a torn
    # read does not fail loudly, it reports "no tokens", 401s the user, and
    # then writes that empty array back, destroying every token. rename(2) is
    # atomic within a filesystem, which the temp file guarantees by living in
    # TOKEN_DIR.
    def save_tokens(tokens)
      TOKEN_DIR.mkpath unless TOKEN_DIR.exist?
      tmp = TOKEN_DIR.join(".tokens.json.#{Process.pid}.#{SecureRandom.hex(4)}")
      begin
        # Create with 0600 from the start so the token file is never briefly
        # world-readable between creation and chmod.
        tmp.open(File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          f.write(JSON.pretty_generate(tokens.map { |t| harden(t) }))
          f.flush
          f.fsync
        end
        tmp.rename(TOKEN_FILE.to_s)
      ensure
        tmp.unlink if tmp.exist?
      end
      # Narrows any pre-existing file that predates this change.
      TOKEN_FILE.chmod(0o600)
    end

    private

    # The digest for a stored entry, or nil when it holds no credential.
    # Entries written before hashing carry a plaintext `token`; save_tokens
    # replaces it with its digest the next time the file is written. Only a
    # String is a credential: `to_s` would turn an unquoted `"token": 123456`
    # into a working token.
    def stored_digest(attrs)
      hashed = attrs[:token_digest]
      return hashed if hashed.is_a?(String) && hashed.match?(/\A\h{64}\z/)

      legacy = attrs[:token]
      legacy.is_a?(String) && legacy.present? ? digest(legacy) : nil
    end

    def harden(attrs)
      return attrs unless attrs.key?(:token)

      hashed = stored_digest(attrs)
      rest = attrs.except(:token)
      hashed ? rest.merge(token_digest: hashed) : rest
    end
  end

  def initialize(attrs = {})
    @id           = attrs[:id]
    @name         = attrs[:name]
    @token_digest = attrs[:token_digest]
    @created_at   = attrs[:created_at]
    @last_used_at = attrs[:last_used_at]
  end

  # Timestamps for display. The store is a plain JSON file the installation
  # guide tells operators they may write by hand, and `date -Iseconds` is not
  # portable — BSD date on macOS rejects it outright. A malformed value must
  # not take down the whole token page, and the raw string is more useful to
  # whoever has to fix it than a blank cell would be.
  def created_at_display(fallback = '-')
    format_timestamp(created_at, fallback)
  end

  def last_used_at_display(fallback)
    format_timestamp(last_used_at, fallback)
  end

  def destroy
    self.class.with_lock do
      tokens = self.class.load_tokens
      tokens.reject! { |t| t[:id] == id }
      self.class.save_tokens(tokens)
    end
    true
  end

  private

  def format_timestamp(value, fallback)
    return fallback if value.blank?

    Time.parse(value.to_s).strftime('%Y-%m-%d %H:%M')
  rescue ArgumentError, TypeError
    value.to_s
  end
end
