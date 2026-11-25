# frozen_string_literal: true

require 'etc'
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
    SESSIONS_PAGE = '/pun/sys/dashboard/batch_connect/sessions'
    LIMIT = 20

    Session = Struct.new(:id, :app, :title, :cluster_id, :job_id, :status, :created_at, keyword_init: true)
    App = Struct.new(:token, :title, :description, :fields, :launch_page, keyword_init: true)

    # What the Dashboard's own form fields ask, for an app's form that uses
    # them without a label of its own.
    STANDARD_FIELDS = {
      'bc_num_hours'        => 'Number of hours',
      'bc_num_slots'        => 'Number of nodes',
      'bc_queue'            => 'Partition',
      'bc_account'          => 'Account',
      'bc_email_on_started' => 'Email when the session starts',
      'bc_vnc_resolution'   => 'Resolution',
      'bc_vnc_idle'         => 'Idle timeout',
      'num_cores'           => 'Number of cores',
      'node_type'           => 'Node type',
      'gpus'                => 'GPUs',
      'auto_queues'         => 'Partition',
      'auto_accounts'       => 'Account'
    }.freeze

    module_function

    # The user's most recent sessions, newest first.
    #
    # @return [Array<Session>]
    def list(clusters:, user: nil)
      recent = records.first(LIMIT)
      statuses = statuses(recent, clusters, user)
      recent.map do |record|
        Session.new(
          id:         record['id'].to_s,
          app:        record['token'].to_s,
          title:      record['title'].to_s.empty? ? app_title(record['token']) : record['title'].to_s,
          cluster_id: record['cluster_id'].to_s,
          job_id:     record['job_id'].to_s,
          status:     statuses.fetch(record['id'].to_s, 'unknown'),
          created_at: created_at(record)
        )
      end
    end

    # Where the Dashboard keeps one JSON record per session, under its data
    # root, found as the Dashboard finds it.
    def db
      env = OodApi::SiteConfig.dashboard_env
      root = [env['OOD_DATAROOT'], env['RAILS_DATAROOT']].map(&:to_s).find { |v| !v.strip.empty? }
      root ||= "~/#{ENV.fetch('OOD_PORTAL', 'ondemand')}/data/sys/dashboard"
      Pathname.new(File.expand_path(root)).join('batch_connect', 'db')
    end

    def records
      found = db.children.select(&:file?).reject { |path| path.extname == '.bak' }.filter_map { |path| record(path) }
      found.sort_by { |record| -(record['created_at'].is_a?(Numeric) ? record['created_at'] : 0) }
    rescue SystemCallError
      []
    end

    def record(path)
      data = JSON.parse(path.read(encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError, EncodingError
      nil
    end

    # Each session's status by its id. The Dashboard marks a session it has
    # seen finish; the rest are looked up with one query per cluster for the
    # user's jobs, where a job the scheduler no longer lists has finished.
    def statuses(records, clusters, user)
      found = {}
      records.group_by { |r| r['cluster_id'].to_s }.each do |cluster_id, list|
        done, open = list.partition { |r| r['cache_completed'] }
        done.each { |r| found[r['id'].to_s] = 'completed' }
        next if open.empty?

        jobs = current_jobs(clusters.find { |c| c.id.to_s == cluster_id }, user)
        open.each { |r| found[r['id'].to_s] = job_status(jobs, r['job_id'].to_s) }
      end
      found
    end

    def job_status(jobs, job_id)
      return 'unknown' if jobs.nil? || job_id.empty?

      jobs.fetch(job_id, 'completed')
    end

    # @return [Hash{String => String}, nil] job id to status; nil when unknown
    def current_jobs(cluster, user)
      return nil unless cluster

      cluster.job_adapter.info_where_owner(user || Etc.getpwuid(Process.uid).name).to_h do |info|
        [info.id.to_s, info.status.to_s]
      end
    rescue StandardError
      nil
    end

    def created_at(record)
      seconds = record['created_at']
      seconds.is_a?(Numeric) ? Time.at(seconds).iso8601 : nil
    end

    # The interactive apps installed as system apps: those with a form, each
    # sub-app listed on its own as the Dashboard lists it.
    #
    # @return [Array<App>]
    def apps
      root = OodApi::SiteConfig.sys_apps
      return [] unless root.directory?

      root.children.select(&:directory?).sort.flat_map do |dir|
        base = form_file(dir, 'form')
        next [] unless base

        manifest = manifest(dir)
        subs = sub_apps(dir)
        next [app(dir, manifest, [base])] if subs.empty?

        subs.map { |name, file| app(dir, manifest, [base, file], name) }
      end
    rescue SystemCallError
      []
    end

    def app(dir, manifest, files, sub = nil)
      form = merged(files)
      token = ["sys/#{dir.basename}", sub].compact.join('/')
      App.new(
        token:       token,
        title:       text(form['title']) || default_title(dir, manifest, sub),
        description: text(form['description']) || manifest['description'].to_s.strip,
        fields:      form['__templated'] ? [] : fields(form),
        launch_page: "/pun/sys/dashboard/batch_connect/#{token}/session_contexts/new"
      )
    end

    def default_title(dir, manifest, sub)
      title = manifest['name'].to_s.empty? ? dir.basename.to_s : manifest['name'].to_s
      sub ? "#{title}: #{sub.tr('_-', '  ').split.map(&:capitalize).join(' ')}" : title
    end

    def text(value)
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end

    # The sub-apps' form files, by name: in the site's app config directory
    # (/etc/ood/config/apps/<app>) when the Dashboard reads it, else in the
    # app's local/ directory. As in the Dashboard, a name's .yml.erb wins
    # over its .yml.
    def sub_apps(dir)
      root = sub_app_root(dir)
      return [] unless root.directory? && root.readable? && root.executable?

      root.children.select(&:file?).filter_map do |file|
        name = file.basename.to_s.split('.').first
        [name, file] if form_file(root, name) == file
      end.sort_by(&:first)
    end

    def sub_app_root(dir)
      env = OodApi::SiteConfig.dashboard_env
      external = (ENV['OOD_LOAD_EXTERNAL_BC_CONFIG'] || env['OOD_LOAD_EXTERNAL_BC_CONFIG'] || 'true').to_s
      config_root = Pathname.new(ENV['OOD_BC_APP_CONFIG_ROOT'] || env['OOD_BC_APP_CONFIG_ROOT'] ||
                                 '/etc/ood/config/apps').join(dir.basename)
      return config_root if !['false', '0', 'no', 'off'].include?(external.downcase) && config_root.directory?

      dir.join('local')
    end

    def form_file(root, name)
      ["#{name}.yml.erb", "#{name}.yml"].map { |f| root.join(f) }.find(&:file?)
    end

    # The form the files make together, each overriding the one before as
    # the Dashboard merges them. A templated file is rendered by the
    # Dashboard, so its fields are not guessed; its form is marked instead.
    def merged(files)
      files.reduce({}) do |form, file|
        next form.merge('__templated' => true) if file.extname == '.erb'

        data = YAML.safe_load(file.read(encoding: 'UTF-8'))
        data.is_a?(Hash) ? deep_merge(form, data) : form
      rescue SystemCallError, Psych::Exception, EncodingError
        form
      end
    end

    def deep_merge(base, over)
      base.merge(over) { |_, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? deep_merge(a, b) : b }
    end

    # What the form asks the user, in order.
    def fields(form)
      return [] unless form['form'].is_a?(Array)

      attributes = form['attributes'].is_a?(Hash) ? form['attributes'] : {}
      form['form'].map(&:to_s).reject { |name| hidden?(attributes[name]) }.map { |name| label(name, attributes[name]) }
    end

    def label(name, attribute)
      given = attribute.is_a?(Hash) ? attribute['label'].to_s : ''
      given.empty? ? STANDARD_FIELDS.fetch(name, name) : given
    end

    # A field the site fixed to one value, which the user does not see.
    def hidden?(attribute)
      return true unless attribute.nil? || attribute.is_a?(Hash)

      attribute.is_a?(Hash) && attribute['widget'].to_s == 'hidden_field'
    end

    def manifest(dir)
      data = YAML.safe_load(dir.join('manifest.yml').read(encoding: 'UTF-8'))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, Psych::Exception, EncodingError
      {}
    end

    def app_title(token)
      found = apps.find { |app| app.token == token.to_s }
      found ? found.title : token.to_s.split('/').last.to_s
    end
  end
end
