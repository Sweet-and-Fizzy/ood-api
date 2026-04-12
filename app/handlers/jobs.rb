# frozen_string_literal: true

require 'pathname'
require 'ood_core'
require_relative 'errors'
require_relative 'clusters'

module Handlers
  module Jobs
    def self.list(clusters:, cluster_id:, user:)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      jobs = cluster.job_adapter.info_where_owner(user)
      [jobs, cluster]
    rescue OodCore::JobAdapterError => e
      raise AdapterError, "Scheduler error: #{e.message}"
    end

    def self.get(clusters:, cluster_id:, job_id:)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      job = cluster.job_adapter.info(job_id)
      raise NotFoundError, 'Job not found' if job.id.nil? || job.id.to_s.empty?

      [job, cluster]
    rescue OodCore::JobAdapterError
      raise NotFoundError, 'Job not found'
    end

    def self.submit(clusters:, cluster_id:, script_content:, workdir: nil, **options)
      raise ValidationError, 'script.content must be a string' unless script_content.is_a?(String)
      raise ValidationError, 'script.content cannot be empty' if script_content.strip.empty?

      workdir = workdir || '/tmp'
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      script = OodCore::Job::Script.new(
        content:       script_content,
        workdir:       Pathname.new(workdir),
        job_name:      options[:job_name],
        queue_name:    options[:queue_name],
        accounting_id: options[:accounting_id],
        wall_time:     options[:wall_time],
        output_path:   options[:output_path] ? Pathname.new(options[:output_path]) : nil,
        error_path:    options[:error_path] ? Pathname.new(options[:error_path]) : nil,
        native:        options[:native]
      )
      job_id = cluster.job_adapter.submit(script)
      job_info = cluster.job_adapter.info(job_id)
      [job_info, cluster]
    rescue OodCore::JobAdapterError => e
      raise AdapterError, "Job submission failed: #{e.message}"
    end

    def self.cancel(clusters:, cluster_id:, job_id:)
      cluster = Clusters.get(clusters: clusters, id: cluster_id)
      cluster.job_adapter.delete(job_id)
      { job_id: job_id, status: 'cancelled' }
    rescue OodCore::JobAdapterError => e
      raise AdapterError, "Failed to cancel job: #{e.message}"
    end
  end
end
