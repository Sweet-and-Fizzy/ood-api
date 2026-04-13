# frozen_string_literal: true

require 'mcp'
require_relative '../handlers/audit'
require_relative '../handlers/jobs'

class ListJobsTool < MCP::Tool
  tool_name 'list_jobs'
  description 'List jobs on a cluster for the current user'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' }
    },
    required: ['cluster_id']
  })

  def self.call(server_context:, cluster_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    jobs, _cluster = Handlers::Audit.log(op: 'list_jobs', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Jobs.list(
        clusters: OodApi::App.clusters,
        cluster_id: cluster_id,
        user: user
      )
    end
    if jobs.empty?
      text = "No jobs found on cluster #{cluster_id} for user #{user}."
    else
      lines = jobs.map do |j|
        "- #{j.id}: #{j.job_name || '(unnamed)'} [#{j.status}] queue=#{j.queue_name}"
      end
      text = "Found #{jobs.size} job(s) on #{cluster_id}:\n#{lines.join("\n")}"
    end
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class GetJobTool < MCP::Tool
  tool_name 'get_job'
  description 'Get details for a specific job on a cluster'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' },
      job_id: { type: 'string', description: 'Job identifier' }
    },
    required: %w[cluster_id job_id]
  })

  def self.call(server_context:, cluster_id:, job_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    job, cluster = Handlers::Audit.log(op: 'get_job', user: user, source: 'mcp', cluster: cluster_id, job_id: job_id) do
      Handlers::Jobs.get(
        clusters: OodApi::App.clusters,
        cluster_id: cluster_id,
        job_id: job_id
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
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class ListHistoricJobsTool < MCP::Tool
  tool_name 'list_historic_jobs'
  description 'List historic (completed) jobs on a cluster'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' }
    },
    required: ['cluster_id']
  })

  def self.call(server_context:, cluster_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    jobs, _cluster = Handlers::Audit.log(op: 'list_historic_jobs', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Jobs.historic(
        clusters: OodApi::App.clusters,
        cluster_id: cluster_id
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
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class SubmitJobTool < MCP::Tool
  tool_name 'submit_job'
  description 'Submit a batch job to a cluster'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' },
      script_content: { type: 'string', description: 'Job script content (bash)' },
      workdir: { type: 'string', description: 'Working directory for the job' },
      job_name: { type: 'string', description: 'Name for the job' },
      queue_name: { type: 'string', description: 'Queue/partition to submit to' },
      accounting_id: { type: 'string', description: 'Account or project to charge' },
      wall_time: { type: 'integer', description: 'Wall time limit in seconds' },
      output_path: { type: 'string', description: 'Path for stdout output' },
      error_path: { type: 'string', description: 'Path for stderr output' },
      native: { description: 'Native scheduler directives (passed through to the scheduler)' },
      after: { type: 'array', items: { type: 'string' }, description: 'Job IDs that must start before this job' },
      afterok: { type: 'array', items: { type: 'string' }, description: 'Job IDs that must complete successfully' },
      afternotok: { type: 'array', items: { type: 'string' }, description: 'Job IDs that must complete with errors' },
      afterany: { type: 'array', items: { type: 'string' }, description: 'Job IDs that must complete (any status)' }
    },
    required: %w[cluster_id script_content]
  })

  def self.call(server_context:, cluster_id:, script_content:, workdir: nil,
                job_name: nil, queue_name: nil, accounting_id: nil,
                wall_time: nil, output_path: nil, error_path: nil,
                native: nil, after: nil, afterok: nil, afternotok: nil, afterany: nil, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    job_info, cluster = Handlers::Audit.log(op: 'submit_job', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Jobs.submit(
        clusters: OodApi::App.clusters,
        cluster_id: cluster_id,
        script_content: script_content,
        workdir: workdir,
        job_name: job_name,
        queue_name: queue_name,
        accounting_id: accounting_id,
        wall_time: wall_time,
        output_path: output_path,
        error_path: error_path,
        native: native,
        after: after,
        afterok: afterok,
        afternotok: afternotok,
        afterany: afterany
      )
    end
    text = "Job submitted successfully.\nJob ID: #{job_info.id}\nCluster: #{cluster.id}\nStatus: #{job_info.status}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class CancelJobTool < MCP::Tool
  tool_name 'cancel_job'
  description 'Cancel a running or queued job on a cluster'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' },
      job_id: { type: 'string', description: 'Job identifier to cancel' }
    },
    required: %w[cluster_id job_id]
  })

  def self.call(server_context:, cluster_id:, job_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    result = Handlers::Audit.log(op: 'cancel_job', user: user, source: 'mcp', cluster: cluster_id, job_id: job_id) do
      Handlers::Jobs.cancel(
        clusters: OodApi::App.clusters,
        cluster_id: cluster_id,
        job_id: job_id
      )
    end
    text = "Job #{result[:job_id]} has been cancelled."
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class HoldJobTool < MCP::Tool
  tool_name 'hold_job'
  description 'Put a queued job on hold'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' },
      job_id: { type: 'string', description: 'Job ID to hold' }
    },
    required: %w[cluster_id job_id]
  })

  def self.call(server_context:, cluster_id:, job_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    Handlers::Audit.log(op: 'hold_job', user: user, source: 'mcp', cluster: cluster_id, job_id: job_id) do
      Handlers::Jobs.hold(clusters: OodApi::App.clusters, cluster_id: cluster_id, job_id: job_id)
    end
    MCP::Tool::Response.new([{ type: 'text', text: "Job #{job_id} held." }])
  rescue Handlers::NotFoundError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class ReleaseJobTool < MCP::Tool
  tool_name 'release_job'
  description 'Release a held job back to the queue'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' },
      job_id: { type: 'string', description: 'Job ID to release' }
    },
    required: %w[cluster_id job_id]
  })

  def self.call(server_context:, cluster_id:, job_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    Handlers::Audit.log(op: 'release_job', user: user, source: 'mcp', cluster: cluster_id, job_id: job_id) do
      Handlers::Jobs.release(clusters: OodApi::App.clusters, cluster_id: cluster_id, job_id: job_id)
    end
    MCP::Tool::Response.new([{ type: 'text', text: "Job #{job_id} released." }])
  rescue Handlers::NotFoundError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end
