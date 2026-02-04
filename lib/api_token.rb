# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'fileutils'

module OodApi
  # Manages API tokens stored in user's home directory
  # Tokens are stored at ~/.config/ondemand/tokens.json
  # Compatible with OOD Dashboard's ApiToken model
  class ApiToken
    TOKENS_DIR = File.expand_path('~/.config/ondemand')
    TOKENS_FILE = File.join(TOKENS_DIR, 'tokens.json')

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
          return new(attrs) if tokens_match?(attrs[:token].to_s, plain_token.to_s)
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

        tokens = load_tokens
        tokens << token_attrs
        save_tokens(tokens)

        [new(token_attrs), plain_token]
      end

      # Delete a token by ID
      def destroy(id)
        tokens = load_tokens.reject { |t| t[:id] == id }
        save_tokens(tokens)
      end

      # Update last_used_at for a token
      def touch(token)
        tokens = load_tokens
        token_data = tokens.find { |t| t[:id] == token.id }
        return unless token_data

        token_data[:last_used_at] = Time.now.iso8601
        save_tokens(tokens)
      end

      private

      def load_tokens
        return [] unless File.exist?(TOKENS_FILE)

        JSON.parse(File.read(TOKENS_FILE), symbolize_names: true)
      rescue JSON::ParserError
        []
      end

      def save_tokens(tokens)
        FileUtils.mkdir_p(TOKENS_DIR)
        File.write(TOKENS_FILE, JSON.pretty_generate(tokens))
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
