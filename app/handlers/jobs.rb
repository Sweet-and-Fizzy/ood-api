# frozen_string_literal: true

require 'pathname'
require 'ood_core'
require_relative 'errors'
require_relative 'clusters'
require_relative 'files'
require_relative 'audit'

module Handlers
  module Jobs
    def self.list(clusters:, cluster_id:, user:)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      jobs = Handlers.with_adapter(cluster, 'list jobs') { cluster.job_adapter.info_where_owner(user) }
      [jobs, cluster]
    end

    def self.historic(clusters:, cluster_id:, user:, opts: {})
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      jobs = Handlers.with_adapter(cluster, 'get job history') do
        cluster.job_adapter.info_historic(opts: opts)
      end
      # Filter by user — some adapters (e.g., Slurm sacct) may return
      # cluster-wide history, not just the current user's jobs.
      jobs = jobs.select { |j| j.job_owner == user } if user
      [jobs, cluster]
    end

    # A job id that is not well-formed text reaches the adapter, which shells
    # out and fails on the encoding — reported as 503, implying our scheduler
    # is down when in fact the caller sent a malformed id.
    def self.validate_job_id!(job_id)
      return if job_id.to_s.valid_encoding?

      raise ValidationError, 'job id is not valid UTF-8'
    end

    def self.get(clusters:, cluster_id:, job_id:)
      validate_job_id!(job_id)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)

      # Deliberately does NOT map JobAdapterError to NotFoundError. The adapter
      # already separates the two cases: an id the scheduler has never heard of
      # comes back as Info(status: :completed) — caught by the shape check
      # below — while a scheduler it cannot reach raises. Collapsing both into
      # 404 told clients "this job does not exist" during an outage, which is a
      # confident wrong answer rather than an honest 503, and one a client may
      # act on by resubmitting.
      job = Handlers.with_adapter(cluster, 'get job') do
        cluster.job_adapter.info(job_id)
      end

      # Adapters echo the requested id back rather than signalling "no such
      # job", so `job.id` is always populated and cannot be used to detect a
      # miss. A job the scheduler has never heard of — or one aged out of the
      # queue past MinJobAge — comes back as :completed with every other field
      # nil. Treat that shape as not-found so callers can tell it apart from a
      # job that genuinely finished, which always carries an owner.
      raise NotFoundError, 'Job not found' if job.id.nil? || job.id.to_s.empty?
      raise NotFoundError, 'Job not found' if job.job_owner.nil? && job.status.to_s == 'completed'

      [job, cluster]
    end

    # Paths the scheduler will write to on the user's behalf get the same
    # treatment as paths the file tools touch.
    def self.job_path!(path)
      return if path.nil? || path.to_s.empty?

      Files.validate_path!(Files.normalize_path(path))
    end

    # wall_time reaches the scheduler unmodified; a non-numeric value silently
    # became "no limit" rather than an error.
    def self.validate_wall_time(value)
      return nil if value.nil?

      seconds = Integer(value)
      raise ValidationError, 'options.wall_time must be greater than zero' if seconds < 1

      seconds
    rescue TypeError, ArgumentError
      raise ValidationError, 'options.wall_time must be an integer number of seconds'
    end

    def self.build_script(content, workdir, options)
      OodCore::Job::Script.new(
        content:       content,
        workdir:       Pathname.new(workdir),
        job_name:      options[:job_name],
        queue_name:    options[:queue_name],
        accounting_id: options[:accounting_id],
        wall_time:     validate_wall_time(options[:wall_time]),
        output_path:   options[:output_path] ? Pathname.new(options[:output_path]) : nil,
        error_path:    options[:error_path] ? Pathname.new(options[:error_path]) : nil,
        native:        options[:native]
      )
    end

    def self.submit(clusters:, cluster_id:, script_content:, workdir: nil, **options)
      raise ValidationError, 'script.content must be a string' unless script_content.is_a?(String)
      raise ValidationError, 'script.content cannot be empty' if script_content.strip.empty?

      workdir ||= '/tmp'
      cluster = Clusters.get(clusters: clusters, id: cluster_id)

      # The scheduler writes to these paths as the user, so they are subject to
      # the same policy as the file tools. Without this, `output_path` is a
      # write primitive that ignores the allowed roots and the deny-list — a
      # job redirecting stdout to ~/.ssh/authorized_keys would sail past a
      # check that refuses the identical path via write_file.
      job_path!(workdir)
      job_path!(options[:output_path])
      job_path!(options[:error_path])

      script = build_script(script_content, workdir, options)
      deps = [:after, :afterok, :afternotok, :afterany].each_with_object({}) do |k, h|
        h[k] = options[k] if options[k]
      end

      job_id = Handlers.with_adapter(cluster, 'submit job') do
        cluster.job_adapter.submit(script, **deps)
      end

      [info_after_submit(cluster, job_id), cluster]
    end

    # The job is queued by the time this runs. A failure looking up its status
    # must NOT surface as a submission failure — a client told "submit is not
    # supported" will retry and queue a second job. Fall back to a minimal
    # record carrying the id the scheduler already gave us.
    def self.info_after_submit(cluster, job_id)
      Handlers.with_adapter(cluster, 'get submitted job status') do
        cluster.job_adapter.info(job_id)
      end
    rescue AdapterError, NotSupportedError => e
      Audit.emit_event(op: 'submit_job_status_unavailable', user: nil, source: 'internal',
                       job_id: job_id, error: e.message)
      OodCore::Job::Info.new(id: job_id, status: :undetermined)
    end

    # ood_core deliberately swallows "Invalid job id specified" on hold,
    # release and delete — see the `unless /Invalid job id specified/` rescue in
    # its Slurm adapter, commented "assume successful job hold if can't find job
    # id". The adapter therefore returns normally for a job that does not exist,
    # and these operations have no return value to inspect, so the only way to
    # avoid reporting a fabricated status is to confirm the job first.
    #
    # This is best-effort, not a guarantee: the job can still vanish between the
    # lookup and the operation. It converts the common case — a typo'd or
    # long-gone id — from a confident lie into a 404.
    def self.assert_job_exists!(clusters:, cluster_id:, job_id:)
      get(clusters: clusters, cluster_id: cluster_id, job_id: job_id)
    end

    def self.cancel(clusters:, cluster_id:, job_id:)
      assert_job_exists!(clusters: clusters, cluster_id: cluster_id, job_id: job_id)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      Handlers.with_adapter(cluster, 'cancel job') { cluster.job_adapter.delete(job_id) }
      { job_id: job_id, status: 'cancelled' }
    end

    # These two return the ood_core Status vocabulary (see docs/api.md) rather
    # than adapter-specific words like 'held'/'released', which is now also
    # what the read endpoints return — job_json reports the portable status and
    # carries the scheduler's own word separately as native_state. A client can
    # therefore branch on one vocabulary across reads and writes alike.
    def self.hold(clusters:, cluster_id:, job_id:)
      assert_job_exists!(clusters: clusters, cluster_id: cluster_id, job_id: job_id)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      Handlers.with_adapter(cluster, 'hold job') { cluster.job_adapter.hold(job_id) }
      { job_id: job_id, status: 'queued_held' }
    end

    def self.release(clusters:, cluster_id:, job_id:)
      assert_job_exists!(clusters: clusters, cluster_id: cluster_id, job_id: job_id)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      Handlers.with_adapter(cluster, 'release job') { cluster.job_adapter.release(job_id) }
      { job_id: job_id, status: 'queued' }
    end
  end
end
