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
    # The allowlist above grants prefixes, and none of those prefixes is a
    # closed vocabulary. SLURM_ is extended by site SPANK plugins, and the PUN's
    # own environment is site-configurable through nginx_stage's pun_custom_env
    # and pun_custom_env_declarations. So a site can introduce a credential
    # under an already-allowed prefix without ever touching this app's config.
    # SLURM_JWT is the concrete case: `scontrol token` mints a slurmrestd bearer
    # token and the documented idiom exports it into the environment, under the
    # allowed SLURM_ prefix (https://slurm.schedmd.com/jwt.html).
    #
    # The filter belongs on the response, not the request. These values reach an
    # LLM, and under prompt injection the request is attacker-authored — so a
    # control on what may be *asked* is a control the attacker writes. Only a
    # control on what may be *returned* holds. This mirrors OWASP LLM02
    # (Sensitive Information Disclosure), whose controls are all data-side.
    #
    # Per CWE-184 this is a supplement, never the primary control: a deny-list
    # is for catching what a correct allowlist should already have excluded. If
    # it ever fires in production, the allowlist is wrong (CWE-183) and that is
    # the thing to fix. `get` reports a deny-list refusal distinctly from an
    # allowlist miss for exactly this reason — a silent omission would leave an
    # operator with no way to tell a false positive from a missing variable.
    #
    # Stems must carry a credential meaning on their own. Refusing a real
    # variable is not free: it breaks a working site and points the operator at
    # the wrong cause. `_KEY` therefore allows a trailing plural or digit but
    # not arbitrary text — a bare `\b` misses MY_KEYS and SLURM_KEY2, while
    # matching `_KEY` anywhere also refuses SLURM_KEYWORD and LMOD_KEYMAP, which
    # are not credentials. Deliberately absent: SALT and SIGNING, common enough
    # as ordinary words to cost more than they catch.
    DENIED_PATTERN = /
      SECRET | TOKEN | PASSW | PASSPHRASE | CREDENTIAL | PRIVATE |
      JWT | APIKEY | API_KEY |
      _KEY(S|\d+)?\b | KEYRING | KEYFILE | KEYSTORE |
      _PEM\b | _CERT(S|IFICATE)?\b
    /xi

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

    # The allowlist alone, with no deny pass. Separated so the deny pass can
    # tell "the allowlist would have permitted this" from "it was excluded
    # anyway" — only the former is worth reporting.
    def self.allowlist_permits?(name)
      list = allowlist
      list[:exact].include?(name) || list[:prefixes].any? { |p| name.start_with?(p) }
    end

    def self.allowed?(name)
      return false if DENIED_PATTERN.match?(name)

      allowlist_permits?(name)
    end

    def self.filtered_env
      denied = []
      vars = ENV.select do |name, _|
        if DENIED_PATTERN.match?(name) && allowlist_permits?(name)
          # Only worth reporting when the allowlist would otherwise have let it
          # through. Every other denied name is already excluded, so logging it
          # would be noise on every single call.
          denied << name
          false
        else
          allowed?(name)
        end
      end
      warn_denied(denied) unless denied.empty?
      vars.sort.to_h
    end

    # A deny-list hit means the allowlist granted something it should not have
    # (CWE-183) — the deny pass is a backstop and is not meant to be the thing
    # standing between a credential and an LLM. Names only, never values.
    def self.warn_denied(names)
      warn "[ood-api] env allowlist permits credential-shaped #{names.sort.join(', ')}; " \
           'refused by the deny pass. Narrow OOD_API_ENV_ALLOWLIST so the allowlist excludes it.'
    rescue StandardError
      nil # never let diagnostics break a read
    end

    private_class_method :allowlist, :allowlist_permits?, :allowed?, :filtered_env, :warn_denied
  end
end
