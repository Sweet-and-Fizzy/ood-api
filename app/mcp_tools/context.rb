# frozen_string_literal: true

require 'mcp'
require_relative '../handlers/context'

CONTEXT_RESOURCE = MCP::Resource.new(
  uri: 'ood://context',
  name: 'cluster-context',
  description: 'Cluster-specific context and instructions from the HPC site administrators',
  mime_type: 'text/markdown'
)
