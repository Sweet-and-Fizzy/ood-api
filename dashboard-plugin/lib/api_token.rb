# frozen_string_literal: true

# Represents an API token for authenticating programmatic access to OOD.
# Tokens are stored in a user-local JSON file.
#
# Token storage is user-specific: ~/.config/ondemand/tokens.json
# In OOD's per-user PUN architecture, this is the authenticated user's home directory.
class ApiToken
  include ActiveModel::Model

  attr_reader :id, :name, :token, :created_at, :last_used_at, :expires_at

  TOKEN_DIR = Pathname.new('~/.config/ondemand').expand_path
  TOKEN_FILE = TOKEN_DIR.join('tokens.json')

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

      tokens = load_tokens
      tokens << token_attrs
      save_tokens(tokens)

      new(token_attrs)
    end

    def load_tokens
      return [] unless TOKEN_FILE.exist?

      JSON.parse(TOKEN_FILE.read, symbolize_names: true)
    rescue JSON::ParserError => e
      Rails.logger.error("Failed to parse API tokens file: #{e.message}")
      []
    end

    def save_tokens(tokens)
      TOKEN_DIR.mkpath unless TOKEN_DIR.exist?
      TOKEN_FILE.write(JSON.pretty_generate(tokens))
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
    @expires_at   = attrs[:expires_at]
  end

  # Check if token is active (not expired).
  # Note: Token expiration is not currently implemented but the field is
  # reserved for future use.
  def active?
    return false if expires_at && Time.parse(expires_at) < Time.current

    true
  end

  def destroy
    tokens = self.class.load_tokens
    tokens.reject! { |t| t[:id] == id }
    self.class.save_tokens(tokens)
    true
  end

  def touch_last_used!
    tokens = self.class.load_tokens
    token_data = tokens.find { |t| t[:id] == id }
    return false unless token_data

    token_data[:last_used_at] = Time.current.iso8601
    self.class.save_tokens(tokens)
    @last_used_at = token_data[:last_used_at]
    true
  end
end
