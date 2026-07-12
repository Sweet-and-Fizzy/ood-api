# frozen_string_literal: true

require_relative 'errors'

module Handlers
  module Env
    DEFAULT_PREFIXES = ['SLURM_', 'PBS_', 'SGE_', 'LSB_', 'LMOD_', 'MODULE', 'OOD_'].freeze
    DEFAULT_EXACT = ['HOME', 'USER', 'LOGNAME', 'SHELL', 'PATH', 'LANG', 'LC_ALL', 'TERM', 'HOSTNAME', 'SCRATCH',
                     'WORK', 'TMPDIR', 'CLUSTER', 'MANPATH'].freeze

    def self.list(prefix: nil)
      vars = filtered_env
      vars = vars.select { |name, _| name.start_with?(prefix) } if prefix && !prefix.empty?
      vars
    end

    def self.get(name:)
      raise ForbiddenError, 'Access denied: variable not in allowlist' unless allowed?(name)
      raise NotFoundError, 'Environment variable not found' unless ENV.key?(name)

      { name: name, value: ENV.fetch(name, nil) }
    end

    def self.allowlist
      custom = ENV.fetch('OOD_API_ENV_ALLOWLIST', nil)
      if custom
        entries = custom.split(',').map(&:strip).reject(&:empty?).uniq
        prefixes = []
        exact = []
        entries.each do |entry|
          if entry.end_with?('*')
            prefix = entry.chomp('*')
            prefixes << prefix unless prefix.empty?
          else
            exact << entry
          end
        end
        { prefixes: prefixes, exact: exact }
      else
        { prefixes: DEFAULT_PREFIXES, exact: DEFAULT_EXACT }
      end
    end

    def self.allowed?(name)
      list = allowlist
      list[:exact].include?(name) || list[:prefixes].any? { |p| name.start_with?(p) }
    end

    def self.filtered_env
      list = allowlist
      ENV.select do |name, _|
        list[:exact].include?(name) || list[:prefixes].any? { |p| name.start_with?(p) }
      end.sort.to_h
    end

    private_class_method :allowlist, :allowed?, :filtered_env
  end
end
