# frozen_string_literal: true

require_relative 'base'
require_relative '../handlers/usage'

module OodApi
  module Tools
    # MCP tool: the user's storage quotas and allocation balances.
    class GetQuotaAndBalanceTool < Base
      tool_name 'get_quota_and_balance'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Get the user\'s storage quotas (space and number of files used against each limit) and ' \
                  'allocation balances, as the Dashboard shows them in its warnings. Use it for "how much ' \
                  'space do I have left" or "how many hours are left on my allocation".'
      input_schema({ type: 'object', properties: {} })

      def self.run(**_params)
        usage = audited('get_quota_and_balance') { Handlers::Usage.for(current_user) }
        unless usage[:configured]
          return text_response('This site does not publish storage quotas or allocation balances.')
        end

        text_response([*quota_lines(usage[:quotas]), *balance_lines(usage[:balances])].join("\n"))
      end

      def self.quota_lines(quotas)
        return ['No storage quotas are listed for you.'] if quotas.empty?

        ['Storage quotas:', *quotas.map { |q| "- #{quota_line(q)}" }]
      end

      def self.quota_line(quota)
        parts = ["#{McpText.safe_text(quota.path)} (#{owner(quota)})", space(quota)]
        parts << "#{size(quota.user_bytes)} of it yours" if quota.type != 'user' && quota.user_bytes
        parts << files(quota) if quota.used_files
        parts << "as of #{quota.updated_at}" if quota.updated_at
        parts.join(', ')
      end

      def self.owner(quota)
        quota.type == 'user' ? 'your quota' : "shared #{McpText.safe_text(quota.type)}"
      end

      def self.space(quota)
        return "#{size(quota.used_bytes)} used, no limit" unless quota.limit_bytes&.positive?

        "#{size(quota.used_bytes)} of #{size(quota.limit_bytes)} used#{percent(quota.used_bytes, quota.limit_bytes)}"
      end

      def self.files(quota)
        return "#{quota.used_files} files, no limit" unless quota.limit_files&.positive?

        "#{quota.used_files} of #{quota.limit_files} files#{percent(quota.used_files, quota.limit_files)}"
      end

      def self.balance_lines(balances)
        return [] if balances.empty?

        ['Allocation balances:', *balances.map do |b|
          what = [b.project_type, McpText.safe_text(b.project)].reject(&:empty?).join(' ')
          "- #{what.empty? ? 'balance' : what}: #{b.value} #{McpText.safe_text(b.unit)} left" \
          "#{", as of #{b.updated_at}" if b.updated_at}".squeeze(' ')
        end]
      end

      def self.percent(used, limit)
        used && limit&.positive? ? " (#{(100.0 * used / limit).round}%)" : ''
      end

      # Binary units, as the Dashboard shows them.
      def self.size(bytes)
        return 'unknown' unless bytes

        units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']
        value = bytes.to_f
        unit = 0
        while value >= 1024 && unit < units.size - 1
          value /= 1024
          unit += 1
        end
        unit.zero? ? "#{bytes} B" : format('%<v>.1f %<u>s', v: value, u: units[unit])
      end
    end
  end
end
