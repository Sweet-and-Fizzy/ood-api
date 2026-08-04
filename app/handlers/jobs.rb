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

    # Job paths are not files this API writes itself — they are handed to the
    # scheduler layer, and not every backend treats them as inert data. To stay
    # safe across all of them without assuming which one a site runs, the path
    # fields take an allow-list rather than trying to enumerate what to reject.
    #
    # The permitted set is what a real scheduler output path needs and nothing
    # more: alphanumerics, `._-/+=:@~` for path structure and file names, `%`
    # for the job-id token (`slurm-%j.out`), and any non-ASCII codepoint so an
    # accented or CJK username in a path is not refused. What is excluded is
    # the ASCII danger set — spaces, control characters, and punctuation — none
    # of which belongs in a job path. The list is intentionally tight; loosen
    # it only with care, since these values leave the app's control once
    # submitted. General file paths (the file API) are unaffected; this guards
    # only the scheduler-bound path fields.
    JOB_PATH_ALLOWED = %r{\A[A-Za-z0-9._/%+=:@~\u{0080}-\u{10FFFF}-]*\z}

    # Paths the scheduler will write to on the user's behalf get the same
    # treatment as paths the file tools touch.
    def self.job_path!(path)
      return if path.nil? || path.to_s.empty?

      # A path has to be a String. `to_s` below would happily turn a Hash into
      # `{"a"=>1}` and validate that, and Pathname.new then raises TypeError on
      # the original object — a client mistake surfacing as a 500. Reject the
      # shape here, where the other path rules already live.
      raise ValidationError, 'path options must be strings' unless path.is_a?(String)

      # valid_encoding? first: Regexp#match? raises ArgumentError on invalid
      # UTF-8, which would surface as a 500. A malformed path is a bad request,
      # and normalize_path below reports it as one — but only if we reach it.
      unless path.valid_encoding? && path.match?(JOB_PATH_ALLOWED)
        raise ValidationError,
              'job path may contain only letters, digits and ._-/%+=:@~ ' \
              '(no spaces or other punctuation)'
      end

      Files.validate_path!(Files.normalize_path(path))
    end

    # Flags that name a file or directory the scheduler will write to, across
    # the adapters ood_core ships. Long forms may be spelled `--output=PATH` or
    # `--output PATH`; short forms take the next element.
    NATIVE_PATH_FLAGS = [
      '-o', '--output', '-e', '--error', '-D', '--chdir', '--workdir',
      '-oo', '-eo', '-cwd', '-wd', '-w'
    ].freeze

    # Short flags may be written bundled with their value: getopt_long treats
    # `-o/path` as identical to `-o /path`, so checking only the separated form
    # leaves the bundled one unvalidated. Longest-first so `-oo` is tried
    # before `-o` and its value is not mistaken for `o/path`.
    NATIVE_SHORT_PATH_FLAGS = NATIVE_PATH_FLAGS.reject { |f| f.start_with?('--') }
                                               .sort_by { |f| -f.length }.freeze

    NATIVE_LONG_PATH_FLAGS = NATIVE_PATH_FLAGS.select { |f| f.start_with?('--') }.freeze

    # getopt_long accepts any unambiguous abbreviation of a long option, so
    # sbatch reads `--out=PATH` as `--output=PATH`. Matching exact spellings
    # would validate `--output` and let `--out` reach the same destination, so
    # any long flag that is a prefix of a path-bearing one counts as one.
    #
    # This over-matches deliberately: `--o` is ambiguous to sbatch and would be
    # rejected there anyway, and refusing a path the scheduler would not have
    # accepted is the safe direction. Prefix rather than substring, so
    # `--outputfoo` — a different option — is left alone.
    def self.long_path_flag?(flag)
      return false unless flag.start_with?('--') && flag.length > 2

      NATIVE_LONG_PATH_FLAGS.any? { |known| known.start_with?(flag) }
    end

    # %j is Slurm's job-id token. Other schedulers use different tokens, but
    # they all treat an unrecognised one as a literal, so the file still lands
    # inside the validated workdir — the property that matters here.
    def self.default_output_path(workdir)
      File.join(workdir.to_s, 'slurm-%j.out')
    end

    # `native` is off unless a site turns it on.
    #
    # Elsewhere in OOD, `native` comes from a site admin's config rather than
    # from a request, and raw argv is tolerated because OOD ships a Shell app —
    # anyone who can set it already has a terminal. This app removes that
    # assumption: an agent driving these tools over MCP has no shell, and the
    # deny-list is the only thing between it and ~/.ssh/authorized_keys.
    #
    # validate_native_paths! is defence in depth, not a substitute for the
    # gate. It only knows the flags listed above, and `native` is argv for
    # whatever scheduler the site runs.
    def self.native_allowed?
      ENV['OOD_API_ALLOW_NATIVE'] == 'true'
    end

    def self.reject_native!(native)
      return if native.nil? || (native.respond_to?(:empty?) && native.empty?)

      unless native_allowed?
        raise ValidationError,
              'options.native is disabled. It is raw scheduler argv and can override ' \
              'validated job paths, so it is opt-in: set OOD_API_ALLOW_NATIVE=true to enable it.'
      end

      validate_native_paths!(native)
    end

    # Path checking for sites that have opted in.
    #
    # Adapters append `native` AFTER the options this handler validated —
    # ood_core's Slurm adapter builds `-o script.output_path` at slurm.rb:644
    # and concatenates native at :671 — and sbatch honours the last occurrence
    # of a repeated flag. So an unchecked `--output=` here silently overrides
    # the path job_path! just approved.
    #
    # Only path-bearing flags are inspected; `--nodes=4` and site-specific
    # flags pass through untouched.
    # Anything other than a flat array of scalars is refused rather than
    # skipped. Skipping meant a String or Hash `native` bypassed path
    # validation entirely, leaving whatever ood_core made of it to decide the
    # outcome — and a nested array flattens to argv on the way to the
    # scheduler, so its contents are argv too. Numerics are allowed because
    # `['--nodes', 4]` is an ordinary way to write scheduler argv in JSON.
    def self.validate_native_shape!(native)
      return if native.is_a?(Array) && native.all? { |a| a.is_a?(String) || a.is_a?(Numeric) }

      raise ValidationError, 'options.native must be a flat array of strings or numbers'
    end

    def self.validate_native_paths!(native)
      # Anything other than a flat array of scalars is refused rather than
      # skipped. Returning early here meant a String or Hash `native` bypassed
      # path validation entirely, leaving whatever ood_core made of it to
      # decide the outcome — and a nested array flattens to argv on the way to
      # the scheduler, so its contents are argv too.
      return if native.nil?

      validate_native_shape!(native)
      args = native.map(&:to_s)
      index = 0
      while index < args.length
        arg = args[index]
        flag, inline = arg.split('=', 2)

        if NATIVE_PATH_FLAGS.include?(flag) || long_path_flag?(flag)
          # `--output=PATH` carries its value; `-o PATH` takes the next element.
          job_path!(inline || args[index + 1])
          index += inline ? 1 : 2
        elsif (bundled = bundled_path(arg))
          job_path!(bundled)
          index += 1
        else
          index += 1
        end
      end
    end

    # `-o/path` with no separator. Long flags are excluded: `--outputfoo` is a
    # different option, not `--output` with a value, and matching it would
    # refuse flags this app knows nothing about.
    def self.bundled_path(arg)
      flag = NATIVE_SHORT_PATH_FLAGS.find { |f| arg.start_with?(f) && arg.length > f.length }
      return nil unless flag

      value = arg[flag.length..]
      # `-o=path` is handled by the split above; anything starting with `-` is
      # another flag rather than a path.
      return nil if value.start_with?('=', '-')

      value
    end

    # wall_time reaches the scheduler unmodified; a non-numeric value silently
    # became "no limit" rather than an error.
    def self.validate_wall_time(value)
      return nil if value.nil?

      seconds = Integer(value)
      raise ValidationError, 'options.wall_time must be greater than zero' if seconds < 1

      seconds
    # RangeError as well: JSON parses `1e400` to Float::INFINITY, and
    # Integer(Infinity) raises FloatDomainError — a RangeError, not an
    # ArgumentError — so an oversized literal escaped as a 500 rather than a
    # 400. Same for NaN.
    rescue TypeError, ArgumentError, RangeError
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
      reject_native!(options[:native])

      # Always give the adapter an output path, even when the caller omitted
      # one. sbatch lets command-line options beat #SBATCH directives, and
      # ood_core emits `-o` only `unless script.output_path.nil?` — so with no
      # output_path a `#SBATCH --output=~/.ssh/authorized_keys` in the script
      # body took effect, reaching a path the same request would be refused for
      # as output_path. Defaulting it means -o is always on the command line
      # and a script directive can never win.
      #
      # The default matches what Slurm would have done anyway: slurm-<jobid>.out
      # in the working directory, which job_path! has already validated.
      options = options.merge(output_path: default_output_path(workdir)) if options[:output_path].nil?

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
