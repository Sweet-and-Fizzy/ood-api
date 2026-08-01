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

    # ood_core's base adapter defines `accounts` and `queues` as returning [],
    # where `cluster_info` and `info_historic` raise NotImplementedError. So an
    # adapter that cannot answer returns an empty list indistinguishable from
    # "you genuinely have no accounts" — a PBS site got 200 [] where the API
    # documented 501, and no client could tell the two apart.
    #
    # Checking the owning module identifies the inherited no-op exactly, rather
    # than inferring it from an empty result, so a Slurm site with no accounts
    # still correctly gets 200 [].
    def self.adapter_implements?(adapter, method)
      # Only the inherited-base case is treated as unsupported. Anything we
      # cannot introspect — a test double, an adapter using method_missing —
      # is assumed to implement it, so this can never turn a working endpoint
      # into a 501.
      owner = adapter.class.instance_method(method).owner
      owner != OodCore::Job::Adapter
    rescue NameError
      true
    end

    def self.require_adapter_support!(cluster, method, operation)
      return if adapter_implements?(cluster.job_adapter, method)

      raise NotSupportedError,
            "#{operation} is not supported by the '#{cluster.id}' adapter"
    end

    def self.accounts(clusters:, id:)
      cluster = get(clusters: clusters, id: id)
      require_adapter_support!(cluster, :accounts, 'list accounts')
      Handlers.with_adapter(cluster, 'list accounts') { cluster.job_adapter.accounts }
    end

    def self.queues(clusters:, id:)
      cluster = get(clusters: clusters, id: id)
      require_adapter_support!(cluster, :queues, 'list queues')
      Handlers.with_adapter(cluster, 'list queues') { cluster.job_adapter.queues }
    end

    def self.info(clusters:, id:)
      cluster = get(clusters: clusters, id: id)
      Handlers.with_adapter(cluster, 'get cluster info') { cluster.job_adapter.cluster_info }
    end
  end
end
