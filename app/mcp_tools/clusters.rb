# frozen_string_literal: true

require_relative 'base'
require_relative '../../lib/site_clusters'
require_relative '../handlers/clusters'

module OodApi
  module Tools
    # MCP tool: list the clusters that accept jobs.
    class ListClustersTool < Base
      tool_name 'list_clusters'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List all available HPC clusters that allow job submission'
      input_schema({ type: 'object', properties: {} })

      def self.run(**_params)
        clusters = audited('list_clusters') do
          Handlers::Clusters.list(clusters: SiteClusters.all)
        end
        lines = clusters.map do |c|
          title = c.metadata.title || c.id.to_s
          adapter = c.job_config[:adapter]
          host = c.login&.host
          "- #{c.id} (#{title}): adapter=#{adapter}, login=#{host}"
        end
        text = "Found #{clusters.size} cluster(s):\n#{lines.join("\n")}"
        text_response(text)
      end
    end

    # MCP tool: describe one cluster.
    class GetClusterTool < Base
      tool_name 'get_cluster'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Get details for a specific HPC cluster by ID'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' }
        },
        required:   ['cluster_id']
      })

      def self.run(cluster_id:, **_params)
        cluster = audited('get_cluster', cluster: cluster_id) do
          Handlers::Clusters.get(clusters: SiteClusters.all, id: cluster_id)
        end
        title = cluster.metadata.title || cluster.id.to_s
        adapter = cluster.job_config[:adapter]
        host = cluster.login&.host
        text = "Cluster: #{cluster.id}\nTitle: #{title}\nAdapter: #{adapter}\nLogin host: #{host}"
        text_response(text)
      end
    end

    # MCP tool: list the accounts the user can charge on a cluster.
    class ListAccountsTool < Base
      tool_name 'list_accounts'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List accounts available for job submission on a cluster'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' }
        },
        required:   ['cluster_id']
      })

      def self.run(cluster_id:, **_params)
        accounts = audited('list_accounts', cluster: cluster_id) do
          Handlers::Clusters.accounts(clusters: SiteClusters.all, id: cluster_id)
        end
        if accounts.empty?
          text = "No accounts found on cluster #{cluster_id}."
        else
          lines = accounts.map { |a| "- #{a.name} (QoS: #{a.qos.join(', ')})" }
          text = "Accounts on #{cluster_id}:\n#{lines.join("\n")}"
        end
        text_response(text)
      end
    end

    # MCP tool: report a cluster's current node, core and GPU usage.
    class GetClusterInfoTool < Base
      tool_name 'get_cluster_info'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Get resource utilization info for a cluster (nodes, CPUs, GPUs)'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' }
        },
        required:   ['cluster_id']
      })

      def self.run(cluster_id:, **_params)
        info = audited('cluster_info', cluster: cluster_id) do
          Handlers::Clusters.info(clusters: SiteClusters.all, id: cluster_id)
        end
        text = "Nodes: #{info.active_nodes}/#{info.total_nodes} active\n" \
               "CPUs: #{info.active_processors}/#{info.total_processors} active\n" \
               "GPUs: #{info.active_gpus}/#{info.total_gpus} active"
        text_response(text)
      end
    end

    # MCP tool: list a cluster's queues or partitions.
    class ListQueuesTool < Base
      tool_name 'list_queues'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List queues/partitions available on a cluster'
      input_schema({
        type:       'object',
        properties: {
          cluster_id: { type: 'string', description: 'Cluster identifier' }
        },
        required:   ['cluster_id']
      })

      def self.run(cluster_id:, **_params)
        queues = audited('list_queues', cluster: cluster_id) do
          Handlers::Clusters.queues(clusters: SiteClusters.all, id: cluster_id)
        end
        if queues.empty?
          text = "No queues found on cluster #{cluster_id}."
        else
          lines = queues.map { |q| "- #{q.name}" }
          text = "Queues on #{cluster_id}:\n#{lines.join("\n")}"
        end
        text_response(text)
      end
    end
  end
end
