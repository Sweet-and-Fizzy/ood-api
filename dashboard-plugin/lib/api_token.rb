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

  # Every token has an expiry unless the site allows tokens that never
  # expire. ood-api enforces it (OodApi::AppAuth); this model records it and
  # offers the choices. The settings and their defaults mirror
  # OodApi::TokenPolicy in lib/token_policy.rb, so keep the two in step.
  LIFETIMES = [30, 90, 365].freeze
  DEFAULT_LIFETIME = 90
  DEFAULT_MAX_DAYS = 365
  NEVER = 'never'
  attr_reader :id, :name, :token_digest, :created_at, :last_used_at, :expires_at

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

    # @return [Integer] the longest lifetime a token may be given, in days
    def max_days
      days = Integer(setting('OOD_API_TOKEN_MAX_DAYS', :token_max_days) || DEFAULT_MAX_DAYS)
      days.positive? ? days : DEFAULT_MAX_DAYS
    rescue ArgumentError, TypeError
      DEFAULT_MAX_DAYS
    end

    def allow_never?
      ['true', '1', 'yes', 'on'].include?(setting('OOD_API_TOKEN_ALLOW_NEVER', :token_allow_never).to_s.strip.downcase)
    end

    # The lifetimes the form offers: the standard ones the site maximum
    # allows, the maximum itself, and "never" where the site allows it.
    #
    # @return [Array<String>] day counts as strings, and possibly NEVER
    def lifetime_options
      days = (LIFETIMES.select { |lifetime| lifetime <= max_days } | [max_days]).sort
      days.map(&:to_s) + (allow_never? ? [NEVER] : [])
    end

    def default_lifetime
      [DEFAULT_LIFETIME, max_days].min.to_s
    end

    # @param lifetime [String] one of lifetime_options
    # @return [String, nil] an ISO 8601 time, or nil for a token that never expires
    def expiry_for(lifetime)
      return nil if lifetime == NEVER && allow_never?

      days = lifetime_options.include?(lifetime) && lifetime != NEVER ? lifetime.to_i : max_days
      (Time.current + days.days).iso8601
    end

    # Returns [ApiToken, plain_token]. The plaintext exists only in this return
    # value, for the one page render that shows it to the user.
    def generate(name:, lifetime: default_lifetime)
      plain_token = SecureRandom.hex(32)
      token_attrs = {
        id:           SecureRandom.uuid,
        name:         name,
        token_digest: digest(plain_token),
        created_at:   Time.current.iso8601,
        expires_at:   expiry_for(lifetime)
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

    # No expiry recorded, a "never" the site does not allow, or a date beyond
    # the site maximum. Matches OodApi::TokenPolicy.needs_expiry?.
    def needs_expiry?(attrs)
      return true unless attrs.key?(:expires_at)
      return !allow_never? if attrs[:expires_at].nil?

      Time.iso8601(attrs[:expires_at].to_s) > Time.current + max_days.days
    rescue ArgumentError
      false
    end

    # Where the API reads the same setting, in the same order: the
    # environment, the API's env file, then its config.yml.
    def setting(env_name, key)
      value = ENV.fetch(env_name, nil) || app_env[env_name]
      return value unless value.nil? || value.strip.empty?

      app_settings[key.to_s]
    rescue StandardError
      nil
    end

    # The API's directory under /etc/ood/config/apps. It is named after the
    # directory the API is installed in, which is where this plugin's files
    # really are, whatever the plugin link is called.
    def app_config_root
      app = File.basename(File.expand_path('../..', File.realpath(__dir__)))
      File.join('/etc/ood/config/apps', app)
    end

    # The API loads this file when it starts; the Dashboard never does.
    def app_env
      file = File.join(app_config_root, 'env')
      return {} unless File.file?(file)

      File.read(file, encoding: 'UTF-8').scrub.each_line.with_object({}) do |line, vars|
        match = line.match(/\A\s*(?:export\s+)?(OOD_API_TOKEN_\w+)\s*=\s*["']?([^"'#\s]*)/)
        vars[match[1]] = match[2] if match
      end
    rescue StandardError
      {}
    end

    def app_settings
      file = File.join(app_config_root, 'config.yml')
      return {} unless File.file?(file)

      parsed = YAML.safe_load(File.read(file, encoding: 'UTF-8'))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    # Brings a stored entry up to date on its way back to disk: a plaintext
    # token becomes its digest, and an entry with no expiry gets the site
    # maximum, matching lib/api_token.rb.
    def harden(attrs)
      attrs = attrs.merge(expires_at: (Time.current + max_days.days).iso8601) if needs_expiry?(attrs)
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
    @expires_at   = attrs[:expires_at]
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

  # @param never [String] what to show for a token that does not expire
  def expires_at_display(never)
    format_timestamp(expires_at, never)
  end

  # True once the expiry has passed, and for a value that is not a time.
  def expired?
    return false if expires_at.nil?

    Time.iso8601(expires_at.to_s) <= Time.current
  rescue ArgumentError
    true
  end

  def destroy
    self.class.with_lock do
      tokens = self.class.load_tokens
      tokens.reject! { |t| t[:id] == id }
      self.class.save_tokens(tokens)
    end
  end

  private

  def format_timestamp(value, fallback)
    return fallback if value.blank?

    Time.parse(value.to_s).strftime('%Y-%m-%d %H:%M')
  rescue ArgumentError, TypeError
    value.to_s
  end
end
