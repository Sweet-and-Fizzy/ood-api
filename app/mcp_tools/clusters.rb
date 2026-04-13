# frozen_string_literal: true

require 'mcp'
require_relative '../handlers/audit'
require_relative '../handlers/clusters'

class ListClustersTool < MCP::Tool
  tool_name 'list_clusters'
  description 'List all available HPC clusters that allow job submission'
  input_schema({ type: 'object', properties: {} })

  def self.call(server_context:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    clusters = Handlers::Audit.log(op: 'list_clusters', user: user, source: 'mcp') do
      Handlers::Clusters.list(clusters: OodApi::App.clusters)
    end
    lines = clusters.map do |c|
      title = c.metadata.title || c.id.to_s
      adapter = c.job_config[:adapter]
      host = c.login&.host
      "- #{c.id} (#{title}): adapter=#{adapter}, login=#{host}"
    end
    text = "Found #{clusters.size} cluster(s):\n#{lines.join("\n")}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class GetClusterTool < MCP::Tool
  tool_name 'get_cluster'
  description 'Get details for a specific HPC cluster by ID'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' }
    },
    required: ['cluster_id']
  })

  def self.call(server_context:, cluster_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    cluster = Handlers::Audit.log(op: 'get_cluster', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Clusters.get(clusters: OodApi::App.clusters, id: cluster_id)
    end
    title = cluster.metadata.title || cluster.id.to_s
    adapter = cluster.job_config[:adapter]
    host = cluster.login&.host
    text = "Cluster: #{cluster.id}\nTitle: #{title}\nAdapter: #{adapter}\nLogin host: #{host}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class ListAccountsTool < MCP::Tool
  tool_name 'list_accounts'
  description 'List accounts available for job submission on a cluster'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' }
    },
    required: ['cluster_id']
  })

  def self.call(server_context:, cluster_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    accounts = Handlers::Audit.log(op: 'list_accounts', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Clusters.accounts(clusters: OodApi::App.clusters, id: cluster_id)
    end
    if accounts.empty?
      text = "No accounts found on cluster #{cluster_id}."
    else
      lines = accounts.map { |a| "- #{a.name} (QoS: #{a.qos.join(', ')})" }
      text = "Accounts on #{cluster_id}:\n#{lines.join("\n")}"
    end
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class GetClusterInfoTool < MCP::Tool
  tool_name 'get_cluster_info'
  description 'Get resource utilization info for a cluster (nodes, CPUs, GPUs)'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' }
    },
    required: ['cluster_id']
  })

  def self.call(server_context:, cluster_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    info = Handlers::Audit.log(op: 'cluster_info', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Clusters.info(clusters: OodApi::App.clusters, id: cluster_id)
    end
    text = "Nodes: #{info.active_nodes}/#{info.total_nodes} active\n" \
           "CPUs: #{info.active_processors}/#{info.total_processors} active\n" \
           "GPUs: #{info.active_gpus}/#{info.total_gpus} active"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class ListQueuesTool < MCP::Tool
  tool_name 'list_queues'
  description 'List queues/partitions available on a cluster'
  input_schema({
    type: 'object',
    properties: {
      cluster_id: { type: 'string', description: 'Cluster identifier' }
    },
    required: ['cluster_id']
  })

  def self.call(server_context:, cluster_id:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    queues = Handlers::Audit.log(op: 'list_queues', user: user, source: 'mcp', cluster: cluster_id) do
      Handlers::Clusters.queues(clusters: OodApi::App.clusters, id: cluster_id)
    end
    if queues.empty?
      text = "No queues found on cluster #{cluster_id}."
    else
      lines = queues.map { |q| "- #{q.name}" }
      text = "Queues on #{cluster_id}:\n#{lines.join("\n")}"
    end
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::AdapterError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end
