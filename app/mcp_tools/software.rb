# frozen_string_literal: true

require_relative 'base'
require_relative '../handlers/software'
require_relative '../../lib/site_clusters'

module OodApi
  module Tools
    # MCP tool: the software installed as environment modules.
    class ListSoftwareTool < Base
      tool_name 'list_software'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List the software installed on the clusters as environment modules, as the Dashboard\'s ' \
                  'Module Browser shows it: each module\'s versions per cluster, newest first, and any module ' \
                  'that must be loaded first. Use it for "is X installed" or "which versions of X are there".'
      input_schema({
        type:       'object',
        properties: {
          name:       { type: 'string', description: 'Part of a module name to look for, such as python or cuda; ' \
                                                     'case and punctuation are ignored' },
          cluster_id: { type: 'string', description: 'Only this cluster' }
        }
      })

      def self.run(name: nil, cluster_id: nil, **_params)
        result = audited('list_software', cluster: cluster_id) do
          Handlers::Software.find(clusters: SiteClusters.all, name: name, cluster_id: cluster_id)
        end
        return text_response(none(name)) if result[:modules].empty?

        lines = result[:modules].flat_map { |found| describe(found) }
        lines << "#{result[:more]} more module names match; ask about a more specific name." if result[:more].positive?
        lines << 'Load one in a job script or a terminal with `module load <name>/<version>`, after any module ' \
                 'it says to load first.'
        text_response(lines.join("\n"))
      end

      def self.none(name)
        return 'No software modules are listed.' if name.to_s.strip.empty?

        "No software module matches #{McpText.safe_text(name)}."
      end

      def self.describe(found)
        versions = found.versions.map do |v|
          first = v.prerequisites.map { |set| set.join(' + ') }
          after = first.empty? ? '' : " (load first: #{first.map { |s| McpText.safe_text(s) }.join(' or ')})"
          "  #{McpText.safe_text(v.version)} on #{McpText.safe_text(v.cluster_id)}#{after}"
        end
        [McpText.safe_text(found.name), *versions]
      end
    end
  end
end
