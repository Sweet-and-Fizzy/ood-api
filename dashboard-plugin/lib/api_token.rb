# frozen_string_literal: true

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
  attr_reader :id, :name, :token, :created_at, :last_used_at

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

    def find_by_token(token_string)
      return nil if token_string.blank?

      load_tokens.each do |attrs|
        return new(attrs) if tokens_match?(attrs[:token].to_s, token_string.to_s)
      end
      nil
    end

    def generate(name:)
      token_attrs = {
        id:         SecureRandom.uuid,
        name:       name,
        token:      SecureRandom.hex(32),
        created_at: Time.current.iso8601
      }

      with_lock do
        tokens = load_tokens
        tokens << token_attrs
        save_tokens(tokens)
      end

      new(token_attrs)
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

      JSON.parse(TOKEN_FILE.read, symbolize_names: true)
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
          f.write(JSON.pretty_generate(tokens))
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

    def tokens_match?(left, right)
      return false unless left.bytesize == right.bytesize

      left_bytes = left.unpack('C*')
      result = 0
      right.each_byte { |byte| result |= byte ^ left_bytes.shift }
      result.zero?
    end
  end

  def initialize(attrs = {})
    @id           = attrs[:id]
    @name         = attrs[:name]
    @token        = attrs[:token]
    @created_at   = attrs[:created_at]
    @last_used_at = attrs[:last_used_at]
  end

  def destroy
    self.class.with_lock do
      tokens = self.class.load_tokens
      tokens.reject! { |t| t[:id] == id }
      self.class.save_tokens(tokens)
    end
    true
  end

  # Records last-used bookkeeping. Deliberately never raises: the caller has
  # already authenticated, and a read-only or full token store should not turn
  # a valid request into a Dashboard 500.
  def touch_last_used!
    self.class.with_lock do
      tokens = self.class.load_tokens
      token_data = tokens.find { |t| t[:id] == id }
      return false unless token_data

      token_data[:last_used_at] = Time.current.iso8601
      self.class.save_tokens(tokens)
      @last_used_at = token_data[:last_used_at]
    end
    true
  rescue SystemCallError, IOError => e
    Rails.logger.error("Failed to record API token last-used: #{e.class}")
    false
  end
end
