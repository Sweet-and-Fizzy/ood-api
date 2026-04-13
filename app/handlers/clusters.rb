# frozen_string_literal: true

require 'ood_core'
require_relative 'errors'

module Handlers
  module Clusters
    def self.list(clusters:)
      clusters.select(&:job_allow?)
    end

    def self.get(clusters:, id:)
      cluster = clusters.find { |c| c.id.to_s == id.to_s && c.job_allow? }
      raise NotFoundError, 'Cluster not found' unless cluster

      cluster
    end

    def self.accounts(clusters:, id:)
      cluster = get(clusters: clusters, id: id)
      cluster.job_adapter.accounts
    rescue OodCore::JobAdapterError => e
      raise AdapterError, "Failed to list accounts: #{e.message}"
    end

    def self.queues(clusters:, id:)
      cluster = get(clusters: clusters, id: id)
      cluster.job_adapter.queues
    rescue OodCore::JobAdapterError => e
      raise AdapterError, "Failed to list queues: #{e.message}"
    end

    def self.info(clusters:, id:)
      cluster = get(clusters: clusters, id: id)
      cluster.job_adapter.cluster_info
    rescue OodCore::JobAdapterError => e
      raise AdapterError, "Failed to get cluster info: #{e.message}"
    rescue NotImplementedError => e
      raise AdapterError, "Failed to get cluster info: #{e.message}"
    end
  end
end
