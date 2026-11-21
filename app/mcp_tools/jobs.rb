# frozen_string_literal: true

require_relative 'base'
require_relative '../handlers/jobs'

module OodApi
  module Tools
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
            clusters:   OodApi::App.clusters,
            cluster_id: cluster_id,
            user:       current_user
          )
        end
        if jobs.empty?
          text = "No jobs found on cluster #{cluster_id} for user #{current_user}."
        else
          lines = jobs.map do |j|
            "- #{j.id}: #{j.job_name || '(unnamed)'} [#{j.status}] queue=#{j.queue_name}"
          end
          text = "Found #{jobs.size} job(s) on #{cluster_id}:\n#{lines.join("\n")}"
        end
        text_response(text)
      end
    end

    class GetJobTool < Base
      tool_name 'get_job'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Get details for a specific job on a cluster'
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
            clusters:   OodApi::App.clusters,
            cluster_id: cluster_id,
            job_id:     job_id
          )
        end
        text = <<~TEXT.strip
          Job: #{job.id}
          Cluster: #{cluster.id}
          Name: #{job.job_name || '(unnamed)'}
          Owner: #{job.job_owner}
          Status: #{job.status}
          Queue: #{job.queue_name}
          Submitted: #{job.submission_time&.iso8601 || 'N/A'}
          Started: #{job.dispatch_time&.iso8601 || 'N/A'}
          Wall time: #{job.wallclock_time || 'N/A'}
        TEXT
        text_response(text)
      end
    end

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
            clusters:   OodApi::App.clusters,
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
      def self.audit_fields(cluster_id, output_path, error_path, workdir, native, script_content)
        { **Handlers::Jobs.script_audit(script_content),
          cluster:     cluster_id,
          output_path: output_path,
          error_path:  error_path,
          workdir:     workdir,
          native:      native.is_a?(Array) ? native.join(' ') : native }
      end

      def self.run(cluster_id:, script_content:, workdir: nil,
                   job_name: nil, queue_name: nil, accounting_id: nil,
                   wall_time: nil, output_path: nil, error_path: nil,
                   native: nil, after: nil, afterok: nil, afternotok: nil, afterany: nil, **_params)
        audit = audit_fields(cluster_id, output_path, error_path, workdir, native, script_content)
        job_info, cluster = audited('submit_job', **audit) do
          Handlers::Jobs.submit(
            clusters:       OodApi::App.clusters,
            cluster_id:     cluster_id,
            script_content: script_content,
            workdir:        workdir,
            job_name:       job_name,
            queue_name:     queue_name,
            accounting_id:  accounting_id,
            wall_time:      wall_time,
            output_path:    output_path,
            error_path:     error_path,
            native:         native,
            after:          after,
            afterok:        afterok,
            afternotok:     afternotok,
            afterany:       afterany
          )
        end
        text = "Job submitted successfully.\nJob ID: #{job_info.id}\nCluster: #{cluster.id}\nStatus: #{job_info.status}"
        text_response(text)
      end
    end

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
            clusters:   OodApi::App.clusters,
            cluster_id: cluster_id,
            job_id:     job_id
          )
        end
        text = "Job #{result[:job_id]} has been cancelled."
        text_response(text)
      end
    end

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
          Handlers::Jobs.hold(clusters: OodApi::App.clusters, cluster_id: cluster_id, job_id: job_id)
        end
        text_response("Job #{job_id} held.")
      end
    end

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
          Handlers::Jobs.release(clusters: OodApi::App.clusters, cluster_id: cluster_id, job_id: job_id)
        end
        text_response("Job #{job_id} released.")
      end
    end
  end
end
