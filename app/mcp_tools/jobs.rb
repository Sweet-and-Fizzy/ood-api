# frozen_string_literal: true

require_relative 'base'
require_relative '../../lib/site_clusters'
require_relative '../handlers/jobs'
require_relative '../handlers/job_details'

module OodApi
  module Tools
    # MCP tool: list the user's active jobs on a cluster.
    class ListJobsTool < Base
      tool_name 'list_jobs'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List jobs on a cluster for the current user'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' }
        },
        required:   ['cluster_id']
      })

      def self.run(cluster_id:, **_params)
        jobs, _cluster = audited('list_jobs', cluster: cluster_id) do
          Handlers::Jobs.list(
            clusters:   SiteClusters.all,
            cluster_id: cluster_id,
            user:       current_user
          )
        end
        if jobs.empty?
          text = "No jobs found on cluster #{cluster_id} for user #{current_user}."
        else
          lines = jobs.map do |j|
            "- #{j.id}: #{j.job_name || '(unnamed)'} [#{status_text(j)}] queue=#{j.queue_name}"
          end
          text = "Found #{jobs.size} job(s) on #{cluster_id}:\n#{lines.join("\n")}"
        end
        text_response(text)
      end

      # A finished job's portable status is "completed" whether it succeeded,
      # failed, timed out or ran out of memory, so the scheduler's own word
      # follows it.
      def self.status_text(job)
        native = Handlers::JobDetails.value(job.native.is_a?(Hash) ? job.native[:state] : nil)&.downcase
        return job.status.to_s unless job.status.completed? && native && native != 'completed'

        "#{job.status} (#{native})"
      end
    end

    # MCP tool: describe one job.
    class GetJobTool < Base
      tool_name 'get_job'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Get details for a specific job on a cluster: its status and the scheduler\'s own state, ' \
                  'why it ended or is waiting, its working directory and script, and, on Slurm, the files ' \
                  'its output and errors were written to'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' },
          job_id:     { type: 'string', description: 'Job identifier' }
        },
        required:   ['cluster_id', 'job_id']
      })

      def self.run(cluster_id:, job_id:, **_params)
        job, cluster = audited('get_job', cluster: cluster_id,
                                          job_id:  job_id) do
          Handlers::Jobs.get(
            clusters:   SiteClusters.all,
            cluster_id: cluster_id,
            job_id:     job_id
          )
        end
        text_response(describe(job, cluster, Handlers::JobDetails.of(job, cluster.job_config[:adapter])))
      end

      # One line for each thing known about the job; unknown details are left out.
      def self.describe(job, cluster, details)
        rows = [
          ['Job', job.id], ['Cluster', cluster.id], ['Name', job.job_name || '(unnamed)'],
          ['Owner', job.job_owner], ['Status', job.status],
          ['Scheduler state', details[:native_state]], ['Reason', details[:reason]],
          ['Queue', job.queue_name], *times(job, details),
          ['Working directory', details[:work_dir]], ['Script', details[:script]],
          ['Output file', file_line(details, :output)], ['Error file', file_line(details, :error)]
        ]
        rows.to_h.compact.map { |label, value| "#{label}: #{value}" }.join("\n")
      end

      # When it was submitted and started, how long it has run against its
      # limit, and, for a pending job, when the scheduler expects it to start.
      # The time of the answer comes with them, so the reader can work out
      # what has changed since.
      def self.times(job, details)
        [
          ['Submitted', job.submission_time&.iso8601 || 'N/A'],
          ['Started', job.dispatch_time&.iso8601 || 'N/A'],
          ['Expected start', details[:expected_start]],
          ['Run time so far', job.wallclock_time ? duration(job.wallclock_time) : 'N/A'],
          *limit_rows(job),
          ['Checked at', Time.now.utc.iso8601]
        ]
      end

      # The time limit and, while the job runs, the time left before it.
      def self.limit_rows(job)
        limit = job.wallclock_limit
        return [] unless limit&.positive?

        used = job.wallclock_time
        left = job.status.running? && used ? duration([limit - used, 0].max) : nil
        [['Time limit', duration(limit)], ['Time left', left]]
      end

      # Seconds as 1h 07m 14s.
      def self.duration(seconds)
        seconds = seconds.to_i
        hours, rest = seconds.divmod(3600)
        format('%<h>dh %<m>02dm %<s>02ds', h: hours, m: rest / 60, s: rest % 60)
      end

      def self.file_line(details, kind)
        path = details[:"#{kind}_path"]
        path && "#{path} (#{details[:"#{kind}_source"]})"
      end
    end

    # MCP tool: list the user's completed jobs on a cluster.
    class ListHistoricJobsTool < Base
      tool_name 'list_historic_jobs'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List historic (completed) jobs on a cluster'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' }
        },
        required:   ['cluster_id']
      })

      def self.run(cluster_id:, **_params)
        jobs, _cluster = audited('list_historic_jobs',
                                 cluster: cluster_id) do
          Handlers::Jobs.historic(
            clusters:   SiteClusters.all,
            cluster_id: cluster_id,
            user:       current_user
          )
        end
        if jobs.empty?
          text = "No historic jobs found on cluster #{cluster_id}."
        else
          lines = jobs.map do |j|
            "- #{j.id}: #{j.job_name || '(unnamed)'} [#{j.status}]"
          end
          text = "Found #{jobs.size} historic job(s) on #{cluster_id}:\n#{lines.join("\n")}"
        end
        text_response(text)
      end
    end

    # MCP tool: submit a batch job.
    class SubmitJobTool < Base
      tool_name 'submit_job'
      # A job script is arbitrary code run as the user on a compute node: it
      # can delete data and reach the network. Clients use these hints to
      # decide what needs approval, so it is marked accordingly.
      annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: true)
      description 'Submit a batch job to a cluster. The script runs as the user with full access to ' \
                  'their files and the cluster network, so confirm it with the user before submitting.'
      input_schema({
        type:       'object',
        properties: {
          cluster_id:     { type: 'string', description: 'Cluster identifier' },
          script_content: { type: 'string', description: 'Job script content (bash)' },
          workdir:        { type: 'string', description: 'Working directory for the job' },
          job_name:       { type: 'string', description: 'Name for the job' },
          queue_name:     { type: 'string', description: 'Queue/partition to submit to' },
          accounting_id:  { type: 'string', description: 'Account or project to charge' },
          wall_time:      { type: 'integer', description: 'Wall time limit in seconds' },
          output_path:    { type: 'string', description: 'Path for stdout output' },
          error_path:     { type: 'string', description: 'Path for stderr output' },
          native:         { description: 'Raw scheduler arguments. Disabled unless the site sets ' \
                                         'OOD_API_ALLOW_NATIVE=true.' },
          after:          { type: 'array', items: { type: 'string' },
    description: 'Job IDs that must start before this job' },
          afterok:        { type: 'array', items: { type: 'string' },
    description: 'Job IDs that must complete successfully' },
          afternotok:     { type: 'array', items: { type: 'string' },
    description: 'Job IDs that must complete with errors' },
          afterany:       { type: 'array', items: { type: 'string' },
    description: 'Job IDs that must complete (any status)' }
        },
        required:   ['cluster_id', 'script_content']
      })

      # Same fields as the REST twin: the scheduler writes these paths as the
      # user, so an audit record that omits them names nothing that was
      # written. Extracted to keep `call` within the method-length limit.
      def self.audit_fields(cluster_id, script_content, options)
        native = options[:native]
        { **Handlers::Jobs.script_audit(script_content),
          **options.slice(:output_path, :error_path, :workdir),
          cluster: cluster_id,
          native:  native.is_a?(Array) ? native.join(' ') : native }
      end

      # The optional arguments, which are passed through to the handler as
      # they are. Anything else a client sends is dropped here.
      OPTIONS = [:workdir, :job_name, :queue_name, :accounting_id, :wall_time, :output_path, :error_path,
                 :native, :after, :afterok, :afternotok, :afterany].freeze

      def self.run(cluster_id:, script_content:, **params)
        options = params.slice(*OPTIONS)
        job_info, cluster = audited('submit_job', **audit_fields(cluster_id, script_content, options)) do
          Handlers::Jobs.submit(clusters: SiteClusters.all, cluster_id: cluster_id,
                                script_content: script_content, **options)
        end
        text = "Job submitted successfully.\nJob ID: #{job_info.id}\nCluster: #{cluster.id}\nStatus: #{job_info.status}"
        text_response(text)
      end
    end

    # MCP tool: cancel a job.
    class CancelJobTool < Base
      tool_name 'cancel_job'
      annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false)
      description 'Cancel a running or queued job on a cluster'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' },
          job_id:     { type: 'string', description: 'Job identifier to cancel' }
        },
        required:   ['cluster_id', 'job_id']
      })

      def self.run(cluster_id:, job_id:, **_params)
        result = audited('cancel_job', cluster: cluster_id,
                                       job_id:  job_id) do
          Handlers::Jobs.cancel(
            clusters:   SiteClusters.all,
            cluster_id: cluster_id,
            job_id:     job_id
          )
        end
        text = "Job #{result[:job_id]} has been cancelled."
        text_response(text)
      end
    end

    # MCP tool: hold a queued job.
    class HoldJobTool < Base
      tool_name 'hold_job'
      annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Put a queued job on hold'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' },
          job_id:     { type: 'string', description: 'Job ID to hold' }
        },
        required:   ['cluster_id', 'job_id']
      })

      def self.run(cluster_id:, job_id:, **_params)
        audited('hold_job', cluster: cluster_id, job_id: job_id) do
          Handlers::Jobs.hold(clusters: SiteClusters.all, cluster_id: cluster_id, job_id: job_id)
        end
        text_response("Job #{job_id} held.")
      end
    end

    # MCP tool: release a held job.
    class ReleaseJobTool < Base
      tool_name 'release_job'
      annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Release a held job back to the queue'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' },
          job_id:     { type: 'string', description: 'Job ID to release' }
        },
        required:   ['cluster_id', 'job_id']
      })

      def self.run(cluster_id:, job_id:, **_params)
        audited('release_job', cluster: cluster_id, job_id: job_id) do
          Handlers::Jobs.release(clusters: SiteClusters.all, cluster_id: cluster_id, job_id: job_id)
        end
        text_response("Job #{job_id} released.")
      end
    end
  end
end
