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
