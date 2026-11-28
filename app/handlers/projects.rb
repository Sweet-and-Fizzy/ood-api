# frozen_string_literal: true

require 'erb'
require 'etc'
require 'pathname'
require 'time'
require 'yaml'
require_relative 'clusters'
require_relative 'errors'
require_relative 'files'
require_relative 'job_details'
require_relative 'sessions'
require_relative '../../lib/site_config'

module Handlers
  # The user's projects in the Dashboard's Project Manager, read from the
  # files the Project Manager keeps. Each answer holds only what those files
  # say: a launcher's form is filled in by the Dashboard when the page is
  # shown, so its defaults and choices are not reported. Nothing here
  # submits, edits or creates anything, and the Project Manager's list of
  # projects is never created when it is missing.
  module Projects
    DASHBOARD = '/pun/sys/dashboard'
    # The Dashboard's own launcher ids; a launcher filed under another name
    # cannot be opened there.
    LAUNCHER_ID = /\A\w{8}\z/
    PROJECT_ID = /\A[\w.-]{1,64}\z/
    LOOKUP_LIMIT = 256 * 1024
    MANIFEST_LIMIT = 64 * 1024
    FORM_LIMIT = 256 * 1024
    # The job log is never trimmed, and each entry holds what the scheduler
    # said about the job.
    JOB_LOG_LIMIT = 16 * 1024 * 1024
    MAX_PROJECTS = 200
    MAX_LAUNCHERS = 50
    MAX_FIELDS = 100
    MAX_JOBS = 50

    # A file the Project Manager keeps that could not be read, or that does
    # not hold what the Project Manager writes there.
    class Unavailable < StandardError; end

    # One launcher's form could not be read; the rest of the project can.
    class LauncherUnavailable < Error; end

    Project = Struct.new(:id, :name, :description, :directory, :page, :problem, keyword_init: true)
    Launcher = Struct.new(:id, :title, :fields, :page, keyword_init: true)
    Job = Struct.new(:id, :cluster_id, :name, :last_known_status, :status, :submitted_at, keyword_init: true)
    Details = Struct.new(:project, :launchers, :launchers_problem, :jobs, :jobs_problem, :more_jobs,
                         keyword_init: true)

    module_function

    # @return [Hash] :projects, and :more, how many were left out past the limit
    # @raise [Unavailable] when the list of projects cannot be read
    def list
      entries = lookup
      projects = entries.first(MAX_PROJECTS).map { |id, dir| project(id, dir) }
      { projects: projects, more: [entries.size - MAX_PROJECTS, 0].max }
    end

    # @return [Details]
    # @raise [NotFoundError] when the user has no project with this id
    # @raise [Unavailable] when the list of projects cannot be read
    def get(id, clusters:, user: nil)
      found = find(id)
      details = Details.new(project: found, launchers: [], jobs: [], more_jobs: 0)
      return details if found.problem

      dir = Pathname.new(found.directory)
      begin
        details.launchers = launchers(dir, found.id)
      rescue Unavailable => e
        details.launchers_problem = e.message
      end
      begin
        logged = job_log(dir)
        details.more_jobs = [logged.size - MAX_JOBS, 0].max
        details.jobs = with_live_status(logged.last(MAX_JOBS).reverse, clusters, user)
      rescue Unavailable => e
        details.jobs_problem = e.message
      end
      details
    end

    # The launcher's page in the Dashboard, where the user checks its form
    # and submits it.
    #
    # @return [Array(Project, Launcher)]
    def launcher(project_id, launcher_id)
      found = find(project_id)
      raise Unavailable, found.problem if found.problem

      missing = "no launcher #{launcher_id.to_s.inspect} in project #{found.id}"
      raise NotFoundError, missing unless launcher_id.to_s.match?(LAUNCHER_ID)

      dir = Pathname.new(found.directory)
      form = launchers_dir(dir).join(launcher_id.to_s, 'form.yml')
      raise NotFoundError, missing unless form.file?

      [found, read_launcher(form, dir, found.id).first]
    rescue Unavailable => e
      raise if found.nil? || found.problem

      raise LauncherUnavailable, "launcher #{launcher_id} in project #{found.id} could not be read: #{e.message}"
    end

    def find(id)
      id = id.to_s
      raise NotFoundError, "no project #{id.inspect}" unless id.match?(PROJECT_ID)

      dir = lookup.to_h[id]
      raise NotFoundError, "no project #{id}" unless dir

      project(id, dir)
    end

    def data_root
      OodApi::SiteConfig.dashboard_data_root.join('projects')
    end

    # The Project Manager's list of the user's projects, by id. A missing
    # list means the user has no projects yet; it is the Project Manager's
    # to create.
    #
    # @return [Array<Array(String, String)>]
    def lookup
      file = data_root.join('.project_lookup')
      return [] if missing?(file)

      data = load_yaml(file.realpath, LOOKUP_LIMIT)
      return [] if data.nil?
      raise Unavailable, "#{file} does not hold a list of projects" unless data.is_a?(Hash)

      data.filter_map do |id, dir|
        [id.to_s, dir] if id.to_s.match?(PROJECT_ID) && dir.is_a?(String) && !dir.empty?
      end
    end

    def project(id, dir)
      real = allowed_directory(dir)
      manifest = load_yaml(inside(real, real.join('.ondemand', 'manifest.yml')), MANIFEST_LIMIT)
      raise Unavailable, 'its manifest does not describe a project' unless manifest.is_a?(Hash)

      Project.new(id: id, name: text(manifest['name']) || id, description: text(manifest['description']).to_s,
                  directory: real.to_s, page: page(id))
    rescue Unavailable, SystemCallError, ArgumentError => e
      Project.new(id: id, name: id, description: '', directory: dir.to_s.scrub.delete("\0"), page: page(id),
                  problem: "unavailable: #{problem_text(e)}")
    end

    # The project's directory, with its links resolved, when it is in one of
    # the allowed roots. The Dashboard lets a project be anywhere, so a
    # project elsewhere is reported, not hidden.
    def allowed_directory(dir)
      real = Pathname.new(dir).realpath
      raise Unavailable, 'its directory is not a directory' unless real.directory?
      return real if allowed_roots.any? { |root| under?(real, root) }

      raise Unavailable, 'its directory is outside the places this site lets the assistant read'
    rescue Errno::ENOENT
      raise Unavailable, 'its directory no longer exists'
    end

    # Where the file tools may read (the site's file allowlist, or home and
    # the temp directories without one), the Dashboard's data root, where it
    # makes a project by default, and the shared project locations. A shared
    # location that is not absolute, or is /, allows nothing.
    def allowed_roots
      shared = OodApi::SiteConfig.shared_project_paths.select(&:absolute?).filter_map do |root|
        real = root.realpath
        real.root? ? nil : real
      rescue SystemCallError
        nil
      end
      (file_roots + [real_or_nil(data_root)] + shared).compact.uniq
    end

    def file_roots
      Files.allowed_path_roots
    end

    def real_or_nil(path)
      path.realpath
    rescue SystemCallError
      nil
    end

    def under?(path, root)
      path == root || path.to_s.start_with?("#{root.to_s.chomp('/')}/")
    end

    # A file of the project's own, which a link may not take elsewhere.
    def inside(project_dir, file)
      real = file.realpath
      raise Unavailable, "#{file.basename} links outside the project" unless under?(real, project_dir)

      real
    rescue Errno::ENOENT
      raise Unavailable, "#{file.relative_path_from(project_dir)} is missing"
    end

    def launchers_dir(dir)
      dir.join('.ondemand', 'launchers')
    end

    # The project's launchers, oldest first as the Project Manager shows them.
    def launchers(dir, project_id)
      found = launcher_forms(dir).first(MAX_LAUNCHERS * 4).filter_map do |form|
        read_launcher(form, dir, project_id)
      rescue Unavailable
        nil
      end
      found.sort_by { |(launcher, created)| [created, launcher.id] }.first(MAX_LAUNCHERS).map(&:first)
    rescue SystemCallError => e
      raise Unavailable, problem_text(e)
    end

    def launcher_forms(dir)
      root = launchers_dir(dir)
      return [] unless root.directory?

      root.children.select { |child| child.basename.to_s.match?(LAUNCHER_ID) }
          .map { |child| child.join('form.yml') }.select(&:file?)
    end

    # @return [Array(Launcher, Integer)] the launcher and when it was made
    def read_launcher(form, dir, project_id)
      data = load_yaml(inside(dir, form), FORM_LIMIT)
      raise Unavailable, "#{form.basename} is not a launcher" unless data.is_a?(Hash)

      id = form.dirname.basename.to_s
      fields = data['form'].is_a?(Array) ? data['form'].first(MAX_FIELDS).map(&:to_s) : []
      launcher = Launcher.new(id: id, title: text(data['title']) || id, fields: fields,
                              page: "#{page(project_id)}/launchers/#{ERB::Util.url_encode(id)}")
      [launcher, data['created_at'].is_a?(Integer) ? data['created_at'] : 0]
    end

    # The jobs the Project Manager logged when it submitted them, oldest
    # first, each with the status it last saw.
    def job_log(dir)
      file = dir.join('.ondemand', 'job_log.yml')
      return [] if missing?(file)

      data = load_yaml(inside(dir, file), JOB_LOG_LIMIT)
      return [] if data.nil?
      raise Unavailable, 'its job log does not hold a list of jobs' unless data.is_a?(Array)

      data.select { |job| job.is_a?(Hash) && !job['id'].to_s.empty? }.map do |job|
        Job.new(id: job['id'].to_s, cluster_id: job['cluster'].to_s, name: job['job_name'].to_s,
                last_known_status: logged_status(job),
                submitted_at: time(job['submission_time']))
      end
    end

    # The status the Project Manager last saw, with the scheduler's own word
    # for a finished job when the log kept it, such as "completed (failed)".
    def logged_status(job)
      status = job['status'].to_s
      return 'unknown' if status.empty?

      native = job['native'].is_a?(Hash) ? job['native'] : {}
      JobDetails.status_text(status, native['state'] || native[:state])
    end

    def finished?(status)
      status == 'completed' || status.start_with?('completed (')
    end

    # Whether a file is simply not there. One that cannot be looked at, or a
    # link to nothing, is not missing but unavailable.
    def missing?(file)
      File.lstat(file)
      file.realpath
      false
    rescue Errno::ENOENT
      raise Unavailable, "#{file.basename} is a link to nothing" if File.symlink?(file)

      true
    rescue SystemCallError => e
      raise Unavailable, "#{file.basename} could not be read (#{e.class.name.split('::').last})"
    end

    # Each job's status now. The user's own jobs come from one query per
    # cluster, as list_jobs reports them. A job not among them, such as a
    # teammate's in a shared project, is asked about by its id, as the
    # Project Manager does. On a cluster the site does not offer, or whose
    # scheduler did not answer the first query, the status now is unknown.
    def with_live_status(jobs, clusters, user)
      open = jobs.reject { |job| finished?(job.last_known_status) }
      live = open.map(&:cluster_id).uniq.to_h do |cluster_id|
        [cluster_id, Sessions.current_jobs(find_cluster(clusters, cluster_id), user)]
      end
      jobs.each { |job| job.status = status_now(job, live[job.cluster_id], clusters) }
    end

    def status_now(job, statuses, clusters)
      return job.last_known_status if finished?(job.last_known_status)
      return 'unknown' if statuses.nil?

      statuses.fetch(job.id) { job_status(find_cluster(clusters, job.cluster_id), job.id) }
    end

    def find_cluster(clusters, id)
      clusters.find { |c| c.id.to_s == id && Clusters.offered?(c) }
    end

    def job_status(cluster, job_id)
      return 'unknown' unless cluster

      info = cluster.job_adapter.info(job_id)
      status = info.status.to_s
      return 'unknown' if status == 'undetermined' || status.empty?

      JobDetails.status_text(status, info.native.is_a?(Hash) ? info.native[:state] : nil)
    rescue StandardError
      'unknown'
    end

    def time(value)
      case value
      when Time then value.iso8601
      when Integer then Time.at(value).iso8601
      end
    end

    # Plain YAML, as the Project Manager writes it, with no aliases and no
    # objects but times. nil for an empty file. The file is opened without
    # following a link and read only if it is a regular file, so a link
    # swapped in after the checks, or a pipe that would never end, is
    # refused. Only the last part of the path is held to this: a directory
    # above it swapped for a link in the moment between the check and the
    # read can still be followed, which exposes at most a name or title
    # from a file the user can read anyway.
    def load_yaml(file, limit)
      text = File.open(file, File::RDONLY | File::NONBLOCK | File::NOFOLLOW, binmode: true) do |io|
        raise Unavailable, "#{file.basename} is not a regular file" unless io.stat.file?

        io.read(limit + 1) || +''
      end
      raise Unavailable, "#{file.basename} is larger than #{limit / 1024} KiB" if text.bytesize > limit

      YAML.safe_load(text.force_encoding(Encoding::UTF_8), permitted_classes: [Time], aliases: false)
    rescue Psych::Exception, EncodingError, ArgumentError
      raise Unavailable, "#{file.basename} could not be understood"
    rescue SystemCallError => e
      raise Unavailable, "#{file.basename} could not be read (#{e.class.name.split('::').last})"
    end

    def problem_text(error)
      return 'its directory could not be understood' if error.is_a?(ArgumentError)

      error.is_a?(SystemCallError) ? "it could not be read (#{error.class.name.split('::').last})" : error.message
    end

    def page(id)
      "#{DASHBOARD}/projects/#{ERB::Util.url_encode(id)}"
    end

    def text(value)
      value.is_a?(String) && !value.strip.empty? ? value.strip : nil
    end
  end
end
