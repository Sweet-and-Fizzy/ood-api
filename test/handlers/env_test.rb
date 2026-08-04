# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/env'

class HandlersEnvTest < Minitest::Test
  def setup
    @saved_env = {}
    # Save and set test env vars
    ['OOD_API_ENV_ALLOWLIST'].each do |key|
      @saved_env[key] = ENV.fetch(key, nil)
    end
    ENV.delete('OOD_API_ENV_ALLOWLIST')

    # Set known test variables
    ENV['SLURM_JOB_ID'] = '12345'
    ENV['SLURM_CLUSTER'] = 'cluster1'
    ENV['PBS_JOBID'] = '99999'
    ENV['HOME'] ||= '/home/testuser'
    ENV['SECRET_PASSWORD'] = 'hunter2'
  end

  def teardown
    @saved_env.each do |key, val|
      if val.nil?
        ENV.delete(key)
      else
        ENV[key] = val
      end
    end
    ENV.delete('SLURM_JOB_ID')
    ENV.delete('SLURM_CLUSTER')
    ENV.delete('PBS_JOBID')
    ENV.delete('SECRET_PASSWORD')
  end

  # --- list ---

  def test_list_returns_allowed_vars
    result = Handlers::Env.list
    assert result.key?('SLURM_JOB_ID')
    assert result.key?('HOME')
  end

  def test_list_excludes_disallowed_vars
    result = Handlers::Env.list
    refute result.key?('SECRET_PASSWORD')
  end

  def test_list_filters_by_prefix
    result = Handlers::Env.list(prefix: 'SLURM_')
    assert result.key?('SLURM_JOB_ID')
    assert result.key?('SLURM_CLUSTER')
    refute result.key?('PBS_JOBID')
    refute result.key?('HOME')
  end

  def test_list_returns_sorted_keys
    result = Handlers::Env.list
    keys = result.keys
    assert_equal keys.sort, keys
  end

  # --- get ---

  def test_get_returns_value
    result = Handlers::Env.get(name: 'SLURM_JOB_ID')
    assert_equal({ name: 'SLURM_JOB_ID', value: '12345' }, result)
  end

  def test_get_raises_forbidden_for_blocked_var
    assert_raises(Handlers::ForbiddenError) do
      Handlers::Env.get(name: 'SECRET_PASSWORD')
    end
  end

  def test_get_raises_not_found_for_unset_var
    ENV.delete('SLURM_NONEXISTENT_VAR')
    assert_raises(Handlers::NotFoundError) do
      Handlers::Env.get(name: 'SLURM_NONEXISTENT_VAR')
    end
  end

  def test_get_returns_empty_string_value
    ENV['SLURM_EMPTY_VAR'] = ''
    result = Handlers::Env.get(name: 'SLURM_EMPTY_VAR')
    assert_equal({ name: 'SLURM_EMPTY_VAR', value: '' }, result)
  ensure
    ENV.delete('SLURM_EMPTY_VAR')
  end

  # --- custom allowlist ---

  def test_custom_allowlist_replaces_defaults
    ENV['OOD_API_ENV_ALLOWLIST'] = 'SITE_NOTE,CUSTOM_*'
    ENV['SITE_NOTE'] = 'note'
    ENV['CUSTOM_VAR'] = 'hello'

    result = Handlers::Env.list
    assert result.key?('SITE_NOTE')
    assert result.key?('CUSTOM_VAR')
    refute result.key?('SLURM_JOB_ID'), 'Default prefix SLURM_ should not be included with custom allowlist'
    refute result.key?('HOME'), 'Default exact match HOME should not be included with custom allowlist'
  ensure
    ENV.delete('CUSTOM_VAR')
    ENV.delete('SITE_NOTE')
  end

  # An allowlist alone is not enough: the scheduler prefixes it grants are
  # exactly where credentials show up. SLURM_JWT is a real Slurm variable
  # holding a bearer token for slurmrestd, and it matches the allowed `SLURM_`
  # prefix — so it leaked under any site policy until the deny pass existed.
  # PASSW needs the W, so the two commonest abbreviations of "password" both
  # slipped past while PASSWORD was caught. BEARER, OAUTH, HMAC and a REFRESH
  # in a scheduler variable are unambiguous credential stems.
  def test_denies_credential_abbreviations_and_auth_stems
    ['SLURM_PASS', 'SLURM_PWD', 'SLURM_BEARER', 'SLURM_OAUTH', 'SLURM_REFRESH', 'SLURM_SIGNATURE',
     'SLURM_HMAC'].each do |name|
      assert Handlers::Env::DENIED_PATTERN.match?(name), "#{name} is credential-shaped"
    end
  end

  # AUTH, SESSION, COOKIE and NONCE have ordinary meanings and are deliberately
  # absent, on the same reasoning that excluded SALT. The \\b anchors must also
  # keep PASSTHROUGH and REFRESHED out of the abbreviation stems.
  def test_ambiguous_and_neighbouring_names_stay_allowed
    ['SLURM_PASSTHROUGH', 'SLURM_REFRESHED', 'SLURM_AUTH', 'SLURM_SESSION', 'SLURM_COOKIE', 'SLURM_NONCE',
     'SLURM_JOB_ID'].each do |name|
      refute Handlers::Env::DENIED_PATTERN.match?(name), "#{name} must not be refused"
    end
  end

  def test_denies_credentials_that_match_an_allowed_prefix
    ENV['SLURM_JWT'] = 'a-real-token'
    ENV['OOD_API_SECRET_KEY'] = 'shh'
    ENV['MODULES_AWS_KEY'] = 'shh'

    result = Handlers::Env.list
    refute result.key?('SLURM_JWT'), 'SLURM_JWT must never be disclosed'
    refute result.key?('OOD_API_SECRET_KEY')
    refute result.key?('MODULES_AWS_KEY')
    assert result.key?('SLURM_JOB_ID'), 'ordinary SLURM_ variables must still be allowed'
  ensure
    ['SLURM_JWT', 'OOD_API_SECRET_KEY', 'MODULES_AWS_KEY'].each { |k| ENV.delete(k) }
  end

  # Credential names are routinely pluralised, numbered, or spelled with a
  # word other than "key" or "token". A `\b`-anchored suffix matches SLURM_KEY
  # but not MY_KEYS or SLURM_KEY2, so these were disclosed with their values.
  def test_denies_credential_names_with_suffixes_and_synonyms
    names = ['SLURM_KEYRING', 'OOD_PASSPHRASE', 'MY_KEYS', 'LMOD_KEYFILE', 'SLURM_PEM', 'SLURM_CERT',
             'SLURM_CERTIFICATE', 'OOD_KEYSTORE', 'SLURM_KEY2']
    names.each { |n| ENV[n] = 'shh' }
    ENV['OOD_API_ENV_ALLOWLIST'] = names.join(',')

    result = Handlers::Env.list
    names.each do |n|
      refute result.key?(n), "#{n} is credential-shaped and must not be disclosed"
      assert_raises(Handlers::ForbiddenError) { Handlers::Env.get(name: n) }
    end
  ensure
    names.each { |n| ENV.delete(n) }
  end

  # Widening the deny pattern must not start refusing ordinary variables. A
  # false positive is not a safe default here: it breaks a working site and
  # says "looks like a credential", which points the operator at the wrong
  # cause. The first four below are the trap — they contain KEY, SALT or
  # SIGNING as ordinary words, and an unanchored pattern refuses all of them.
  def test_ordinary_variables_are_not_denied
    allowed = ['SLURM_KEYWORD', 'LMOD_KEYMAP', 'MODULE_SALT_FLATS', 'OOD_SIGNING_OFF',
               'SLURM_JOB_ID', 'SLURM_NTASKS', 'SLURM_NODELIST', 'SLURM_SUBMIT_DIR', 'SLURM_JOB_PARTITION',
               'PBS_JOBID', 'PBS_O_WORKDIR', 'SGE_TASK_ID', 'SGE_ROOT', 'LSB_JOBID', 'LMOD_CMD',
               'LMOD_PKG', 'MODULEPATH', 'MODULESHOME', 'OOD_PORT', 'SLURM_CPU_BIND']
    allowed.each do |n|
      refute Handlers::Env::DENIED_PATTERN.match?(n), "#{n} is an ordinary variable, not a credential"
    end
  end

  # CWE-184: a deny-list is for detecting what a correct allowlist should have
  # excluded. If it fires, the allowlist is wrong, and nobody finds out unless
  # it says so — the list path silently drops the variable.
  def test_a_deny_pass_hit_on_an_allowlisted_name_is_reported
    ENV['OOD_API_ENV_ALLOWLIST'] = 'SLURM_*'
    ENV['SLURM_JWT'] = 'a-real-token'

    _, err = capture_io { Handlers::Env.list }

    assert_match(/SLURM_JWT/, err, 'the operator must learn which name the allowlist wrongly permitted')
    assert_match(/allowlist/i, err, 'the message must point at the allowlist, not just report a refusal')
    refute_match(/a-real-token/, err, 'the value must never be logged')
  ensure
    ENV.delete('SLURM_JWT')
  end

  # A name the allowlist never granted is denied anyway, so reporting it would
  # be noise on every call — the default environment is full of such names.
  def test_no_warning_for_a_credential_the_allowlist_already_excludes
    ENV['OOD_API_ENV_ALLOWLIST'] = 'SLURM_*'
    ENV['AWS_SECRET_ACCESS_KEY'] = 'shh'

    _, err = capture_io { Handlers::Env.list }

    assert_empty err.strip, 'only an allowlist mistake is worth reporting'
  ensure
    ENV.delete('AWS_SECRET_ACCESS_KEY')
  end

  # The deny pass is a backstop, not something a site can opt out of.
  def test_deny_pass_overrides_an_explicit_allowlist_entry
    ENV['OOD_API_ENV_ALLOWLIST'] = 'SLURM_JWT'
    ENV['SLURM_JWT'] = 'a-real-token'

    assert_raises(Handlers::ForbiddenError) { Handlers::Env.get(name: 'SLURM_JWT') }
    refute Handlers::Env.list.key?('SLURM_JWT')
  ensure
    ENV.delete('SLURM_JWT')
  end

  # A site that explicitly allowlists MY_API_KEY and is told it is "not in
  # allowlist" has been handed a false statement and will debug the wrong
  # thing. The deny pass and a genuine allowlist miss are different refusals.
  def test_denied_credential_name_is_reported_distinctly_from_an_allowlist_miss
    ENV['OOD_API_ENV_ALLOWLIST'] = 'MY_API_KEY,SITE_NOTE'
    ENV['MY_API_KEY'] = 'v1'
    ENV['SITE_NOTE'] = 'v3'

    denied = assert_raises(Handlers::ForbiddenError) { Handlers::Env.get(name: 'MY_API_KEY') }
    assert_match(/credential/i, denied.message,
                 'an explicitly allowlisted name refused by the deny pass must say why')

    missing = assert_raises(Handlers::ForbiddenError) { Handlers::Env.get(name: 'NOT_LISTED') }
    assert_match(/not in allowlist/i, missing.message)

    assert_equal 'v3', Handlers::Env.get(name: 'SITE_NOTE')[:value]
  ensure
    ['MY_API_KEY', 'SITE_NOTE'].each { |k| ENV.delete(k) }
  end

  # Regexp#match? raises ArgumentError on invalid UTF-8, and the deny pattern
  # is the FIRST thing Env.get runs — so a malformed name crashed the
  # credential filter before it could refuse, giving a 500 where a 403
  # belonged. A security control must not fall over on hostile input.
  def test_a_name_that_is_not_valid_utf8_is_refused_not_crashed
    [(+"SLURM_\xFF").force_encoding('UTF-8'),
     (+"\xC3\x28").force_encoding('UTF-8'),
     (+"\xFF\xFE_KEY").force_encoding('UTF-8')].each do |bad|
      error = assert_raises(Handlers::ForbiddenError, "#{bad.bytes} must be refused") do
        Handlers::Env.get(name: bad)
      end
      assert_match(/credential/i, error.message)
    end
  end

  # The allowlist is parsed with String#split, which raises on invalid UTF-8.
  # This value comes from the PUN's environment rather than from a request, so
  # one stray byte in a site's OOD_API_ENV_ALLOWLIST took out the endpoint on
  # both surfaces instead of narrowing it.
  def test_a_malformed_allowlist_does_not_break_the_endpoint
    ENV['OOD_API_ENV_ALLOWLIST'] = (+"SLURM_\xFF,HOME").force_encoding('UTF-8')

    result = Handlers::Env.list
    assert_kind_of Hash, result, 'a malformed allowlist entry must not raise'
    assert result.key?('HOME'), 'the well-formed entries must still be honoured'
  ensure
    ENV.delete('OOD_API_ENV_ALLOWLIST')
  end

  # filtered_env runs the same pattern over every name in the real
  # environment. One malformed variable in the PUN's environment took out
  # list_env on both surfaces for every request, not just the caller's.
  def test_a_malformed_variable_name_does_not_break_the_listing
    ENV[(+"BAD_\xFF").force_encoding('UTF-8')] = 'x'
    ENV['SLURM_CONF'] = '/etc/slurm/slurm.conf'

    result = Handlers::Env.list
    assert_equal '/etc/slurm/slurm.conf', result['SLURM_CONF'],
                 'a malformed name elsewhere must not suppress valid variables'
  ensure
    ENV.delete((+"BAD_\xFF").force_encoding('UTF-8'))
    ENV.delete('SLURM_CONF')
  end
end
