# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'errors'
require_relative '../../lib/site_config'

module Handlers
  # The user's storage quotas and allocation balances, from the files the
  # Dashboard reads for its quota and balance warnings: the JSON files or
  # URLs named in OOD_QUOTA_PATH and OOD_BALANCE_PATH, set in the
  # environment or the Dashboard's env file. Version 1 of each format, as
  # the Dashboard reads it.
  module Usage
    # The Dashboard counts quota blocks in kibibytes.
    BLOCK_SIZE = 1024
    READ_LIMIT = 4 * 1024 * 1024
    FETCH_SECONDS = 5

    Quota = Struct.new(:path, :type, :used_bytes, :limit_bytes, :user_bytes, :used_files, :limit_files,
                       :updated_at, keyword_init: true)
    Balance = Struct.new(:project, :value, :unit, :project_type, :updated_at, keyword_init: true)

    module_function

    # @return [Hash] :quotas, :balances, :configured (whether either path is set)
    def for(user)
      quota_paths = paths('OOD_QUOTA_PATH')
      balance_paths = paths('OOD_BALANCE_PATH')
      {
        quotas:     quota_paths.flat_map { |path| quotas(read(path), user) },
        balances:   balance_paths.flat_map { |path| balances(read(path), user) },
        configured: !(quota_paths.empty? && balance_paths.empty?)
      }
    end

    # Colon-separated, where a colon in `scheme://` does not separate.
    def paths(name)
      given = [ENV.fetch(name, nil), OodApi::SiteConfig.dashboard_env[name]].map { |v| v.to_s.strip }
      given.find { |value| !value.empty? }.to_s.split(%r{:(?!//)}).reject(&:empty?)
    end

    def read(path)
      uri = URI.parse(path)
      text = ['http', 'https'].include?(uri.scheme) ? fetch(uri) : File.read(path, READ_LIMIT + 1)
      raise Error, 'too large' if text.nil? || text.bytesize > READ_LIMIT

      json = JSON.parse(text)
      json.is_a?(Hash) ? json : {}
    rescue StandardError
      {}
    end

    def fetch(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: FETCH_SECONDS, read_timeout: FETCH_SECONDS) do |http|
        http.request(Net::HTTP::Get.new(uri)).body
      end
    end

    def quotas(json, user)
      list = json['quotas'].is_a?(Array) ? json['quotas'] : []
      list.select { |q| q.is_a?(Hash) && q['user'].to_s == user.to_s }.map { |q| quota(q, json['timestamp']) }
    end

    def quota(entry, file_timestamp)
      Quota.new(
        path:        entry['path'].to_s,
        type:        entry.fetch('type', 'user').to_s,
        used_bytes:  blocks(entry['total_block_usage']),
        limit_bytes: blocks(entry['block_limit']),
        user_bytes:  blocks(entry['block_usage']),
        used_files:  number(entry['total_file_usage']),
        limit_files: number(entry['file_limit']),
        updated_at:  time(entry.fetch('timestamp', file_timestamp))
      )
    end

    def blocks(value)
      number(value)&.*(BLOCK_SIZE)
    end

    def balances(json, user)
      list = json['balances'].is_a?(Array) ? json['balances'] : []
      config = json['config'].is_a?(Hash) ? json['config'] : {}
      list.select { |b| b.is_a?(Hash) && b['user'].to_s == user.to_s }.map do |b|
        Balance.new(project: b['project'].to_s, value: number(b['value']), unit: config['unit'].to_s,
                    project_type: config['project_type'].to_s,
                    updated_at: time(b.fetch('timestamp', json['timestamp'])))
      end
    end

    def number(value)
      return value.to_i if value.is_a?(Numeric)

      Float(value.to_s).to_i
    rescue ArgumentError
      nil
    end

    def time(seconds)
      seconds.is_a?(Numeric) ? Time.at(seconds).iso8601 : nil
    end
  end
end
