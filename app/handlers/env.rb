# frozen_string_literal: true

require_relative 'errors'

module Handlers
  module Env
    # `MODULE` deliberately has no trailing underscore: the real variables are
    # MODULEPATH, MODULESHOME, and MODULES_CMD. The deny pass below is what
    # keeps that loose prefix from disclosing something like MODULES_AWS_KEY.
    DEFAULT_PREFIXES = ['SLURM_', 'PBS_', 'SGE_', 'LSB_', 'LMOD_', 'MODULE', 'OOD_'].freeze
    DEFAULT_EXACT = ['HOME', 'USER', 'LOGNAME', 'SHELL', 'PATH', 'LANG', 'LC_ALL', 'TERM', 'HOSTNAME', 'SCRATCH',
                     'WORK', 'TMPDIR', 'CLUSTER', 'MANPATH'].freeze

    # Names that are never disclosed, whatever the allowlist says.
    #
    # An allowlist alone is not enough here: the scheduler prefixes it grants
    # are exactly where credentials appear. SLURM_JWT is a standard Slurm
    # variable holding a bearer token for slurmrestd, and it begins with the
    # allowed `SLURM_` prefix — so under any sane site policy it would be
    # disclosed. Since these values reach an LLM, one injected instruction to
    # "summarise my environment" is enough to exfiltrate them.
    #
    # This is a backstop, not a substitute for a careful allowlist. A site that
    # genuinely needs to expose one of these must rename the variable.
    DENIED_PATTERN = /SECRET|TOKEN|PASSW|CREDENTIAL|_JWT\b|JWT_|_KEY\b|APIKEY|API_KEY|PRIVATE/i

    def self.list(prefix: nil)
      vars = filtered_env
      vars = vars.select { |name, _| name.start_with?(prefix) } if prefix && !prefix.empty?
      vars
    end

    def self.get(name:)
      # Distinguish the two refusals. A site that explicitly allowlists
      # MY_API_KEY and is told it is "not in allowlist" has been handed a
      # false statement, and will go looking in the wrong place.
      if DENIED_PATTERN.match?(name)
        raise ForbiddenError,
              'Access denied: the name looks like a credential and is refused regardless of the allowlist'
      end
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
      return false if DENIED_PATTERN.match?(name)

      list = allowlist
      list[:exact].include?(name) || list[:prefixes].any? { |p| name.start_with?(p) }
    end

    def self.filtered_env
      ENV.select { |name, _| allowed?(name) }.sort.to_h
    end

    private_class_method :allowlist, :allowed?, :filtered_env
  end
end
