# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'
require_relative 'errors'
require_relative '../../lib/site_config'

module Handlers
  # The user's interactive app sessions, as the Dashboard records them, and
  # the interactive apps the site offers. Nothing here starts, stops or
  # connects to a session: each answer gives the Dashboard page where the
  # user does that. A session's connection details, which hold its password,
  # are never read.
  module Sessions
    # Where the Dashboard keeps one JSON record per session.
    DB = '~/ondemand/data/sys/dashboard/batch_connect/db'
    SESSIONS_PAGE = '/pun/sys/dashboard/batch_connect/sessions'
    LIMIT = 20

    Session = Struct.new(:id, :app, :title, :cluster_id, :job_id, :status, :created_at, keyword_init: true)
    App = Struct.new(:token, :title, :description, :launch_page, keyword_init: true)

    module_function

    # The user's most recent sessions, newest first.
    #
    # @return [Array<Session>]
    def list(clusters:)
      records.first(LIMIT).map do |record|
        Session.new(
          id:         record['id'].to_s,
          app:        record['token'].to_s,
          title:      record['title'].to_s.empty? ? app_title(record['token']) : record['title'].to_s,
          cluster_id: record['cluster_id'].to_s,
          job_id:     record['job_id'].to_s,
          status:     status(record, clusters),
          created_at: created_at(record)
        )
      end
    end

    def records
      db = Pathname.new(File.expand_path(DB))
      return [] unless db.directory?

      db.children.select(&:file?).reject { |path| path.extname == '.bak' }.filter_map do |path|
        record = JSON.parse(path.read(encoding: 'UTF-8'))
        record.is_a?(Hash) ? record : nil
      rescue JSON::ParserError, SystemCallError, EncodingError
        nil
      end.sort_by { |record| -record['created_at'].to_i }
    end

    # The Dashboard marks a session it has seen finish; any other is asked
    # of its scheduler.
    def status(record, clusters)
      return 'completed' if record['cache_completed']

      cluster = clusters.find { |c| c.id.to_s == record['cluster_id'].to_s }
      return 'unknown' unless cluster && !record['job_id'].to_s.empty?

      cluster.job_adapter.info(record['job_id'].to_s).status.to_s
    rescue StandardError
      'unknown'
    end

    def created_at(record)
      seconds = record['created_at']
      seconds.is_a?(Numeric) ? Time.at(seconds).iso8601 : nil
    end

    # The interactive apps installed as system apps: those with a form.
    #
    # @return [Array<App>]
    def apps
      root = OodApi::SiteConfig.sys_apps
      return [] unless root.directory?

      root.children.select(&:directory?).sort.filter_map do |dir|
        next unless dir.join('form.yml').file? || dir.join('form.yml.erb').file?

        manifest = manifest(dir)
        App.new(
          token:       "sys/#{dir.basename}",
          title:       manifest['name'].to_s.empty? ? dir.basename.to_s : manifest['name'].to_s,
          description: manifest['description'].to_s.strip,
          launch_page: "/pun/sys/dashboard/batch_connect/sys/#{dir.basename}/session_contexts/new"
        )
      end
    end

    def manifest(dir)
      data = YAML.safe_load(dir.join('manifest.yml').read(encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, Psych::Exception, EncodingError
      {}
    end

    def app_title(token)
      name = token.to_s.split('/').last.to_s
      found = apps.find { |app| app.token == token.to_s }
      found ? found.title : name
    end
  end
end
