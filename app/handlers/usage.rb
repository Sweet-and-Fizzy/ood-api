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
    # A site-wide file lists every user on every file system.
    READ_LIMIT = 64 * 1024 * 1024
    CONNECT_SECONDS = 5
    FETCH_SECONDS = 10

    class Unreadable < StandardError; end

    Quota = Struct.new(:path, :type, :used_bytes, :limit_bytes, :user_bytes, :used_files, :limit_files,
                       :updated_at, keyword_init: true)
    Balance = Struct.new(:project, :value, :unit, :project_type, :updated_at, keyword_init: true)

    module_function

    # @return [Hash] :quotas, :balances, :configured (whether either path is
    #   set), :unreadable (how many quota and balance sources could not be read)
    def for(user)
      quota_files = paths('OOD_QUOTA_PATH').map { |path| read(path) }
      balance_files = paths('OOD_BALANCE_PATH').map { |path| read(path) }
      {
        quotas:     quota_files.compact.flat_map { |json| quotas(json, user) },
        balances:   balance_files.compact.flat_map { |json| balances(json, user) },
        configured: !(quota_files.empty? && balance_files.empty?),
        unreadable: { quota: quota_files.count(&:nil?), balance: balance_files.count(&:nil?) }
      }
    end

    # Colon-separated, where only a colon before an absolute path or a URL
    # separates, so the colons in `https://` and in a port do not.
    def paths(name)
      given = [ENV.fetch(name, nil), OodApi::SiteConfig.dashboard_env[name]].map { |v| v.to_s.strip }
      given.find { |value| !value.empty? }.to_s.split(%r{:(?=/(?!/)|[a-z][a-z0-9+.-]*://)}i).reject(&:empty?)
    end

    # One source's JSON object; nil when it cannot be read or is not one.
    def read(path)
      uri = URI.parse(path)
      text = ['http', 'https'].include?(uri.scheme) ? fetch(uri) : File.read(path, READ_LIMIT + 1)
      raise Unreadable, 'too large' if text.nil? || text.bytesize > READ_LIMIT

      json = JSON.parse(text)
      json.is_a?(Hash) ? json : nil
    rescue StandardError
      nil
    end

    # The body of a successful response, read in pieces so that neither a
    # large body nor a slow server holds this app past its limits.
    def fetch(uri)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FETCH_SECONDS
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: CONNECT_SECONDS, read_timeout: CONNECT_SECONDS) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          raise Unreadable, response.code unless response.is_a?(Net::HTTPSuccess)

          return body(response, deadline)
        end
      end
    end

    def body(response, deadline, limit = READ_LIMIT)
      text = +''
      response.read_body do |piece|
        text << piece
        raise Unreadable, 'too large' if text.bytesize > limit
        raise Unreadable, 'too slow' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      end
      text
    end

    def quotas(json, user)
      list = json['quotas'].is_a?(Array) ? json['quotas'] : []
      list.select { |q| q.is_a?(Hash) && q['user'].to_s == user.to_s }.map { |q| quota(q, json['timestamp']) }
    end

    def quota(entry, file_timestamp)
      Quota.new(
        path:        entry['path'].to_s,
        type:        entry['type'].to_s.strip.empty? ? 'user' : entry['type'].to_s,
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
      number = value.is_a?(Numeric) ? value : Float(value.to_s)
      number.finite? ? number.to_i : nil
    rescue ArgumentError, TypeError
      nil
    end

    def time(seconds)
      seconds.is_a?(Numeric) ? Time.at(seconds).iso8601 : nil
    end
  end
end
