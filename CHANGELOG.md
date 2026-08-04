# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- CI now runs `bundler-audit` on every push and pull request. `SECURITY.md`
  documents the dependency-advisory posture including one advisory held open
  behind the Ruby 3.0 floor, and Dependabot cannot report on an accepted-and-
  pinned advisory — so that claim previously rested on someone remembering to
  run the tool by hand. A new advisory now fails the build.

### Fixed

- **`?max_size=%FF` returned a 500.** Rack tags query values UTF-8 without
  validating them, so a regex in the route raised `ArgumentError` and escaped
  the route's rescue list. The same class was fixed in the handlers last
  release; this site lived in the route and was missed. A malformed
  `OOD_API_ENV_ALLOWLIST` broke the environment endpoint the same way, since
  `String#split` also raises on invalid UTF-8.
- **A non-finite number in an MCP tool argument returned an internal error.**
  JSON has no Infinity literal, but `1e400` overflows to `Float::INFINITY` on
  parse, and the schema validator calls `Float#floor` on it — so validation
  died before any handler ran and the app's own numeric guards never
  executed. Non-finite numbers are now refused at the MCP boundary as invalid
  params.
- **`PUT /api/v1/files` returned a 500 through a symlink loop.** A loop makes
  `exist?` false, so the parent-directory create ran on a path that was
  already there and raised `EEXIST`, which the write path did not rescue.
- **Five validators crashed on unexpected input instead of refusing it**,
  turning a client mistake into a 500 on REST and a JSON-RPC internal error on
  MCP. `options.wall_time` and `max_size` rescued `TypeError`/`ArgumentError`
  but not `RangeError`, so an oversized JSON literal like `1e400` — which
  parses to `Float::INFINITY` — escaped as a server fault. The environment
  deny-pattern, the allowlist check, and the scheduler-unavailability matcher
  all ran regexes against unvalidated bytes, and `Regexp#match?` raises on
  invalid UTF-8. The environment one mattered most: the deny pattern is the
  first statement in the lookup, so a malformed name took out the credential
  filter before it could refuse. A name that is not well-formed text is now
  treated as denied, and the unavailability matcher scrubs before matching so
  a malformed byte in scheduler stderr cannot turn a 503 into a 500.
- **A non-string token value in `tokens.json` authenticated.** The stored
  value was compared with `to_s`, so an unquoted `"token": 123456` in a
  hand-edited file yielded a working credential spelled `"123456"`. Only a
  string is now accepted as a stored token.
- **The README recommended a read-only workaround that causes an outage.**
  `OOD_API_MAX_FILE_WRITE=0` was offered as a partial stand-in for the absent
  read-only mode. It stops the MCP endpoint from starting at all, because the
  transport requires a positive byte cap; it rejects every request with a
  body, including job submission, not only writes; and a zero-byte write still
  succeeds, so it does not even block truncation. The known limitation now
  says there is no approximation of a read-only mode.
- **A syntactically valid but wrong-shaped `tokens.json` made every
  authenticated request fail.** Only `JSON::ParserError` was rescued, so a
  file that parsed but was not an array of objects — a bare JSON object, an
  array of strings — reached the callers that index each entry and raised,
  returning 500. Installation docs invite operators to write this file by
  hand, so the wrong shape is a realistic mistake. Both token stores now treat
  an unexpected shape the same as a corrupt file: ignore it, log, and refuse
  to authenticate.
- **`options.native` skipped path validation entirely unless it was an
  array.** The check returned early for any other shape, so a `native` sent as
  a string, an object, or a nested array reached the scheduler without its
  paths being examined. It is now refused with a 400 unless it is a flat array
  of strings or numbers. Only reachable with `OOD_API_ALLOW_NATIVE=true`.
- **`options.native` accepted abbreviated path flags at sites that had opted
  in.** Schedulers accept any unambiguous abbreviation of a long option, so
  `sbatch` reads `--out=PATH` as `--output=PATH` — but path validation matched
  exact spellings, so `--output=` was refused and `--out=` reached the
  scheduler with the same destination. Any long flag that is a prefix of a
  path-bearing one is now validated as path-bearing, which covers every
  abbreviation by construction rather than by enumeration. Only reachable with
  `OOD_API_ALLOW_NATIVE=true`, which is off by default.
- **`touch=false` created the file.** `POST /api/v1/files` tested `touch` for
  presence, and every non-empty string is truthy in Ruby, so the falsey
  spellings a client writes when it means the opposite still created an empty
  file. `true`, `1`, `yes` and `on` now create it and anything else does not.

### Documentation

- `SECURITY.md` said nothing in this app loads the `excon` dependency carrying
  GHSA-48rx-c7pg-q66r. It is loaded transitively when `ood_core` is required.
  The conclusion is unchanged and now stated as verified rather than assumed:
  the app constructs no `Excon` connection and makes no outbound HTTP request.
  `test/docs_test.rb` now holds a socket trip-wire over the request surface,
  so a handler that starts calling out fails the suite before that claim goes
  stale.
- `SECURITY.md` now records what path checking `options.native` still performs
  at sites that opt in, rather than only that the gate exists.
- **The environment deny-pattern was documented as broader than it is.**
  `docs/api.md` said seven credential stems accept a plural or digit suffix;
  only `_KEY` does, `_CERT` takes a plural but not a digit, and the rest match
  no suffix at all, so `X_PASS2` and `X_PWDS` are allowed through. A site
  reading the old text could believe it had coverage it did not. The pass is a
  backstop for a correct allowlist, and the docs now say so.
- **`OOD_API_MAX_FILE_WRITE` was documented as a file-write limit.** It bounds
  the body of every `/api/v1/*` request, so lowering it to restrict uploads
  also caps how large a job script may be.
- `docs/api.md`: documented the 400 from `GET /api/v1/env` when `prefix` is
  repeated or sent as an array; corrected the `touch` values, including that
  case and surrounding whitespace are ignored; widened the 507 summary in both
  tables, which named only "no space left on device" when the endpoint also
  reports disk-quota and file-too-large failures; and listed the `path`
  validation errors on `DELETE /api/v1/files`, which its sibling routes
  already documented.
- `docs/installation.md`: the plugin's `OOD API plugin loaded` line goes to the
  Dashboard's Rails log, not the PUN log.
- `docs/user-guide.md`: `$TMPDIR` is a third allowed root alongside `$HOME` and
  `/tmp`; the off-limits list was missing `~/.local/bin`, `~/.config/git`,
  `~/.config/autostart`, `.gitconfig`, `.netrc`, `.forward` and
  `.pam_environment`; `submit_job` also takes `native`; and JWTs are validated
  by Apache rather than by this app, so a 401 on a bearer token points at the
  IdP.

## [0.4.1] - 2026-08-03

Follow-up fixes to v0.4.0. No API contract changes and nothing to do on
upgrade.

The one worth knowing about is the site-context endpoint: it failed outright
when the PUN's locale was not UTF-8, which an em-dash in a policy fragment was
enough to trigger. The rest are error responses that reported the wrong thing —
a 404 that said `bad_request`, a disk-quota failure that said the disk was
full, and two shapes of malformed request that returned 500 instead of 400.

### Fixed

- **The site-context endpoint failed on ordinary punctuation when the PUN's
  locale was not UTF-8.** Files were read in the locale's encoding, and with
  `LANG` unset that is `US-ASCII` — so an em-dash in an operator's policy note
  raised `Encoding::CompatibilityError` and took out `GET /api/v1/context` and
  the MCP context resource entirely. The PUN's environment is whatever
  `nginx_stage` sets, so this was not hypothetical. Context fragments and both
  token stores are now read as UTF-8, and an invalid byte in a fragment
  degrades that fragment rather than the endpoint.

- `POST /api/v1/jobs` returned 500 when a path option was not a string.
  `job_path!` validated `path.to_s`, so a Hash became the string `{"a"=>1}` and
  passed the check — then `Pathname.new` raised `TypeError` on the original
  object. Path options must now be strings, refused with 400 where the other
  path rules live.

- `POST /api/v1/jobs` returned 500 when `options.native` was not an array. The
  audit field called `join` on it unguarded, so a String or Hash — a client
  mistake — surfaced as a server fault. The handler already tolerated a
  non-array, and the MCP tool already guarded it, so only the REST route
  crashed.

- The MCP `hold_job` and `release_job` tools let a `ValidationError` escape as
  a JSON-RPC internal error, where their five sibling job tools return a clean
  tool error. A malformed job id was reported as a server failure rather than a
  bad argument. REST was already correct.

- `docs/api.md` still documented the `PUT /api/v1/files` 507 as "No space left
  on device" — the exact wording the code fix above removed. The `POST` entry
  already read "The filesystem is full or the user is over quota".

- The MCP `submit_job` schema described `native` as "passed through to the
  scheduler" with no mention that it is off unless a site opts in, so an agent
  would send it and get a 400 it could not explain from the tool description.

- `GET /api/v1/files/content` returned a generic `{"error":"bad_request"}`
  body for every error, including 404 and 403. The route set an
  `application/octet-stream` content type before the read, so any error raised
  afterwards kept it — and the filter that normalises non-JSON error bodies
  then replaced the real message. The content type is now set only on success.
  Status codes were always correct; only the bodies were wrong.

- `PUT /api/v1/files` reported a disk-quota failure as "No space left on
  device". The route discarded the message that distinguishes them, so EDQUOT
  — a per-user home quota, and the case that actually bites on HPC sites —
  looked like a full filesystem. `POST /api/v1/files` already reported it
  correctly, so the two write endpoints disagreed.

- `docs/api.md` listed the credential deny-pattern stems as of v0.3.2, missing
  the seven added in v0.4.0. Since that section states there is no override, an
  operator whose `SLURM_PASS` vanished on upgrade would not have found it in
  the list.

- `docs/installation.md` did not document `OOD_API_ALLOW_NATIVE` or
  `OOD_API_MAX_CONTEXT_TOTAL_BYTES`, and `docs/user-guide.md` still listed
  `native` as an ordinary submit option without noting it is now off by
  default. The v0.4.0 changelog also gave two different counts for the same
  deny-list change; both now say seven, which is what the code adds.

## [0.4.0] - 2026-08-03

Security release. **Sites should upgrade.**

Twenty-two fixes since v0.3.2, most of them in the controls that keep an agent
acting on prompt-injected content from establishing access that outlives the
session. Six were ways past the sensitive-path deny-list: four through symlinks
and case handling on the file endpoints, and two through job submission, where
`options.native` and `#SBATCH` directives could direct a job's output to a path
the same request would be refused for.

**Three changes a site may notice.** `options.native` is now disabled unless
you set `OOD_API_ALLOW_NATIVE=true`. Writes carrying an `X-OOD-API-Token`
header need `Content-Type: application/json` like any other write, which every
documented example already sends. The environment endpoint refuses
seven more credential-shaped stems, so a site whose allowlist exposed a matching
variable will see it disappear.

Everything else is a fix without a contract change: several classes of
malformed input that returned 500 now return a proper status, the site-context
endpoint can no longer be made to hang a worker, and refused authentication is
now recorded in the audit log.

### Security

- **BREAKING: `options.native` is now disabled unless a site opts in.** It is
  raw scheduler argv, and matching flag spellings cannot constrain it —
  `getopt_long` accepts any unambiguous prefix, so refusing `--output` still
  admits `--out`, `--outp` and `--outpu`. Two rounds of patching spellings did
  not converge.

  Every other part of Open OnDemand takes `native` from a trusted source: Batch
  Connect from the site admin's `submit.yml.erb`, filtered through Rails strong
  params so no HTTP caller can inject it; Job Composer from a file the user
  wrote, with no HTTP surface at all. This API was the only one accepting it
  from an arbitrary caller. The ecosystem tolerates raw argv because OOD ships
  a Shell app — a user who can set `native` already has a terminal — and that
  assumption is exactly what an agent driving this API does not satisfy.

  Set `OOD_API_ALLOW_NATIVE=true` to restore it. Job paths are then only as
  constrained as the scheduler makes them.

- **A `#SBATCH` directive in the job script could set the output path.**
  `sbatch` lets command-line options beat script directives, and `ood_core`
  emits `-o` only when `output_path` is set — so a request that omitted it left
  the script free to direct its own output, reaching a path the same request
  would have been refused for as `output_path`. An output path is now always
  supplied, defaulting to `slurm-%j.out` in the validated working directory,
  which is where the scheduler would have written it anyway.

- **`options.native` bypassed the job path deny-list, including when the path
  was bundled with its flag.** `output_path`,
  `error_path` and `workdir` are validated against the allowed roots and the
  sensitive-path deny-list, because the scheduler writes them as the user.
  `native` is raw scheduler argv and was not validated — and `ood_core` appends
  it *after* the flags built from those options, so a `--output=` inside
  `native` silently overrode the path just approved. The same file was refused
  as `output_path` and accepted as `native`.

  That is the invariant SECURITY.md states, and the deny-list is not a
  privilege control: the point is that an agent acting on injected input cannot
  reach `~/.ssh/authorized_keys`, and through `native` it could. Path-bearing
  flags in `native` (`-o`, `--output`, `-e`, `--error`, `-D`, `--chdir` and the
  PBS/LSF/SGE equivalents) are now validated like any other job path, in all
  three spellings — `--output=PATH`, `-o PATH`, and `-oPATH`. `getopt_long`
  treats the bundled form as identical to the separated one, so checking only
  the latter left the same destination reachable. Everything else in `native`
  passes through untouched, including unrelated bundles such as `-N2`.

- **Seven more credential stems are now refused.** `PASSW`
  requires the W, so `SLURM_PASS` and `SLURM_PWD` — the two commonest
  abbreviations — both slipped past while `SLURM_PASSWORD` was caught. Added
  those plus `BEARER`, `OAUTH`, `_HMAC`, `_REFRESH` and `SIGNATURE`. `AUTH`,
  `SESSION`, `COOKIE` and `NONCE` are deliberately still permitted: they have
  ordinary meanings, on the same reasoning that excluded `SALT`.

- **A refused token left no audit record.** Every other refusal in the app logs
  one, but `Audit.log` wraps an operation and a failed authentication has none
  — so repeated guesses against an app token were invisible in the PUN log,
  which is the only place this app records anything. Both REST and MCP now
  record the attempt and the path. The token value is never logged.

- **`submit_job` audit records named no path.** Every file operation logs the
  path it touched; job submission logged only the cluster, despite being the
  one operation whose writes happen out of process. `output_path`,
  `error_path`, `workdir` and `native` are now recorded on both surfaces.

- **A scheduler string that was not valid UTF-8 turned a successful request
  into a 500.** Job names come from the user's own `-J` flag or a filename, so
  a locale-mangled byte is reachable in practice. `to_json` raised after the
  operation had already succeeded — the audit log recorded `status=ok` while
  the caller got an error — and one such job broke `list_jobs` for every job on
  the cluster, not only its own. `Handlers::Audit` already scrubbed for this
  reason, which is why the log survived a response that could not be built.
  Job, cluster and file responses now scrub the same way; invalid bytes render
  as `?` so the value stays recognisable.

- **An unauthenticated caller could trigger a 500 and see a Rack internal
  class name.** Sinatra merges `@request.params` before it runs `before`
  filters, so a malformed body is parsed upstream of authentication — the
  ordering the app documents as ensuring an unauthenticated caller learns
  nothing did not hold for a body Rack cannot parse. A multipart body with too
  many parts escaped as a bare 500; an unparseable one returned Rack's own HTML
  error quoting `Rack::Multipart::EmptyContentError`. Both now return
  `400 {"error":"bad_request"}` as JSON. `/mcp` was never affected — it
  authenticates before touching the body.

- **The site-context endpoint could wedge a worker and had no aggregate
  bound.** A FIFO in `agents.d` reports size 0, so the per-file cap never fired
  and the read blocked until a writer appeared, hanging the PUN worker; a
  device node would never end. Non-regular files are now skipped, matching the
  guard the file handler already applied. Separately, the per-file cap bounded
  nothing on its own — 500 files each under it produced a 125 MiB string before
  JSON encoding — so a total cap now applies, with the truncation marked in the
  output. Both need write access to `/etc/ood/config/agents.d`, so this is
  operator-to-agent rather than caller-to-agent.

- **A fragment filename could forge a trust-boundary marker.** `<!-- Source: -->`
  markers were defanged in file bodies but the filename was interpolated raw,
  so one crafted name emitted two genuine-looking markers and could impersonate
  another fragment to a reading agent. Filenames are now reduced to a
  conservative character set.

- **Widened the sensitive-path deny-list.** Confinement worked, but the list of
  what to confine had gaps that defeat its stated purpose — stopping an agent
  acting on injected input from establishing access that outlives the session.
  Now refused: `.bash_aliases` (sourced by the stock Debian and Ubuntu
  `.bashrc`, so denying `.bashrc` and allowing this protected the door and left
  the window open), `~/.local/bin` (ahead of the system paths in `PATH` by
  default on current Fedora and Ubuntu, so a file there shadows a real
  command), `~/.gitconfig` and `~/.config/git` (`core.pager` and
  `core.sshCommand` run on the next git invocation), `~/.netrc` (plaintext
  credentials), `~/.config/autostart`, `~/.forward`, and `~/.pam_environment`.

  `.vimrc` and `.inputrc` are deliberately still permitted: a user may
  reasonably manage them, and neither is a direct code-execution path.

- **A symlink chain of two or more hops escaped path confinement entirely.**
  The guard resolved a single `readlink`, so with `a -> b -> ~/.ssh/authorized_keys`
  it inspected `b` — an innocuous name — and never saw the real destination.
  One hop was refused; two were not. This defeated the allowed-roots check as
  well as the deny-list, so a chain could write anywhere on the filesystem the
  user can reach, not merely to a denied file. Job `output_path` and
  `error_path` shared it. Chains are now followed to their end, with a hop cap
  so a loop is refused rather than followed forever.

- **The deny-list compared names case-sensitively.** macOS and Windows
  filesystems are usually case-insensitive, so `~/.SSH/authorized_keys` is
  `~/.ssh/authorized_keys` there — but only the lowercase spelling was refused,
  and a write to the uppercase one landed on the canonical denied file. Names
  are now compared case-folded. As with the two symlink bypasses below, this
  only applied to a path that did not exist yet: once it does, `realpath`
  canonicalises the case and the deny-list already caught it.

- **A symlink anywhere above a target bypassed the sensitive-path deny-list.**
  Path validation resolved only as far as the nearest *existing* ancestor. With
  a link such as `~/proj/up -> ~`, a request for `~/proj/up/.ssh/authorized_keys`
  — where neither the key file nor `.ssh` exists yet — resolved to `$HOME`
  itself, whose path relative to home is empty and matches no denied entry. The
  leaf was not a symlink, so the dangling-link guard did not apply either.

  Every denied target was writable in a single call: shell init files,
  `~/.ssh/authorized_keys` (created at the modes sshd accepts), user systemd
  units, and the app's own token store — the last letting a caller install a
  token of their choosing. Job `output_path` and `error_path` were affected
  through the same validation.

  A link pointing back at home is ordinary in HPC home directories, alongside
  the common `~/scratch -> /scratch/$USER` pattern, so this needed no unusual
  setup. Paths are now resolved along their full length, with the components
  below the deepest existing ancestor re-appended, so the deny-list compares
  against the file that would actually be created.

- **A symlink whose target did not yet exist bypassed the sensitive-path
  deny-list.** `Pathname#exist?` follows symlinks, so a dangling link looked
  like a missing file: path validation ascended the link's own directory
  instead of the target's. A link in `/tmp` pointing at `~/.bashrc` therefore
  resolved to `/tmp`, passed the allowed-roots check, and reached the deny-list
  as a pair of paths neither of which was under `$HOME`. The inode check
  returned early for the same reason. The write then followed the link and
  created the file at the target.

  This is the persistence case the deny-list exists to prevent, and absent
  files are the ones worth planting — `.bashrc` and `.zshrc` are missing on
  plenty of HPC accounts, and `~/.ssh/authorized_keys` on any account that has
  never used key authentication. It was reachable through the MCP `write_file`
  tool, so an agent acting on injected content could establish access that
  outlives the session. Existing denied files were always refused correctly;
  only the not-yet-created case was affected.

  Job submission was affected identically, since `output_path`, `error_path`
  and `workdir` are validated through the same code, and the scheduler writes
  those paths as the user.

  Symlink targets are now resolved before the deny-list runs. Ordinary
  dangling links pointing at allowed paths still work.

- The CSRF filter no longer treats the presence of an `X-OOD-API-Token` header
  as grounds to skip the JSON content-type requirement on writes. The header
  was only read, never validated, and in the default configuration
  (`OOD_API_APP_TOKENS` unset) nothing downstream validated it either — so any
  non-empty value disabled the check on exactly the configuration it exists to
  protect. A `POST` with `Content-Type: text/plain` and an invented token
  created the file; it is now refused with 415.

  This was not a working browser exploit: `X-OOD-API-Token` is not
  CORS-safelisted, so a cross-origin `fetch` preflights and the app sends no
  CORS headers, and an HTML form cannot set the header at all. It removed a
  defense-in-depth layer rather than the last one.

  Clients already sending `Content-Type: application/json`, as every
  documented example does, are unaffected. `DELETE` remains exempt: it carries
  no body to mislabel and no HTML form can issue one.

- Widened the environment-variable deny-list. Its suffixes were `\b`-anchored,
  which matches `SLURM_KEY` but not `MY_KEYS` or `SLURM_KEY2`, so
  `SLURM_KEYRING` and `OOD_PASSPHRASE` were disclosed with their values under
  an allowlist granting those prefixes. Added `PASSPHRASE`, `KEYRING`,
  `KEYFILE`, `KEYSTORE`, `_PEM` and `_CERT`.

  The deny pass is a supplement to the allowlist, not the primary control
  (CWE-184). A hit on a name the allowlist permitted means the allowlist is
  wrong (CWE-183), and the list path previously dropped such names silently.
  It now logs the name — never the value — so the allowlist can be corrected.

### Fixed

- `docs/api.md` listed ten credential-name stems for the environment deny
  pass where the code now has twenty-two, and described `_JWT`/`JWT_` where the
  pattern matches `JWT` anywhere. `SLURM_KEYRING`, `OOD_PASSPHRASE`, `MY_PEM`
  and `MY_CERT` were among the names silently refused but documented as
  returned. Since the section states there is no override, an operator whose
  variable vanished had nothing to go on.

- The dashboard's token page showed `curl -H "Authorization: Bearer ..."`
  directly beneath a newly created application token. `Authorization` is owned
  by Apache for the IdP's JWT, and the app reads only `X-OOD-API-Token`, so
  following the one instruction shown at the moment of issuance sent the token
  into a header it was never meant for and never authenticated.

- `bin/dev` now binds `127.0.0.1` rather than every interface. Its own header
  notes that `/mcp` is unauthenticated without a reverse proxy, so binding
  `0.0.0.0` offered an unauthenticated file and job API, running as the
  developer's own user, to anyone on the same network. Set
  `OOD_API_DEV_BIND=0.0.0.0` if a container or VM needs to reach it. This
  affects local development only — under Passenger the bind is OOD's.

- `docs/api.md` described a CSRF exemption for the `X-OOD-API-Token` header
  that no longer exists, and claimed a bodyless `POST ?touch=1` needs no
  `Content-Type` — the filter exempts the `DELETE` method, not bodyless
  requests. Three curl examples returned 415 as written. A docs test now
  scans every documented write example for the required content type.

- The dashboard token page raised `ArgumentError` and returned 500 when a
  token's `created_at` or `last_used_at` could not be parsed. The install
  guide documents writing `tokens.json` by hand with `date -Iseconds`, which
  BSD `date` on macOS does not support, so a malformed timestamp was
  reachable by following the documentation. Unparseable values now render as
  their raw string, which is what whoever has to correct the file needs to
  see.

## [0.3.2] - 2026-08-01

Dependency currency. No API contract changes and nothing to do on upgrade.

`bundler-audit` reported 18 known advisories against v0.3.1, five rated High;
this leaves one. The app now runs the same Sinatra and Rack versions as the
OOD Dashboard itself.

### Changed

- Upgraded Sinatra 3.2.0 → 4.2.1, Rack 2.2.21 → 3.2.6, Puma 7.2.0 → 8.0.2,
  plus `rackup` and `json`. This clears **17 of 18 known dependency
  advisories**, including all five rated High. The one remaining is `excon`,
  which needs Ruby 3.1 from 1.2.6 onward and arrives transitively via
  `ood_core` — taking it would drop OOD 3.x sites, so it waits for the Ruby
  floor to move.

  The `sinatra ~> 3.0` pin had no recorded reason and was not required by the
  Ruby 3.0 floor: Sinatra 4 needs only Ruby 2.7.8. Eleven Rack advisories and
  two Sinatra ones were sitting behind it. Every other pin in the Gemfile
  names the Ruby version that forces it; this one did not, which is why it
  went unexamined.

  Also brings `parser`, `regexp_parser`, and `bigdecimal` up to date, leaving
  only `excon` and `minitest` behind the OOD Dashboard's own lockfile — both
  pinned because they require Ruby 3.1 from their next release, which the
  Dashboard can take and we cannot while OOD 3.x sites are supported.

### Fixed

- Sinatra 4 enables host authorization by default, permitting only localhost,
  which would have rejected every request on a real site with "Host not
  permitted". Disabled for the same reason as the MCP transport's equivalent
  setting: Apache validates `Host` against the portal's `ServerName` and
  authenticates before anything reaches the PUN.

## [0.3.1] - 2026-07-31

Fixes a regression that has left the MCP endpoint non-functional on every real
deployment since v0.2.0, plus a gap in the v0.3.0 CSRF guard.

**Sites running v0.2.0 or v0.3.0 should upgrade.** No API contract changes.

### Fixed

- **The MCP endpoint returned 403 for every request on a real site.** `mcp`
  1.0.0, adopted in v0.2.0, added DNS-rebinding protection defaulting to an
  allowlist of loopback only — so any request whose `Host` is an actual
  hostname was refused. Apache already validates `Host` against the portal's
  `ServerName` and authenticates before anything reaches the PUN, so the
  protection is redundant here and is now disabled. **Sites running v0.2.0 or
  v0.3.0 have a non-functional `/mcp`; REST is unaffected.**
- The CSRF guard exempted any request with an empty body, on the reasoning
  that `DELETE` sends none. But an HTML form with no fields posts an empty
  body with a form content type, so cross-origin `touch`, `mkdir`, `hold`, and
  `release` were still reachable. The exemption is now scoped to the `DELETE`
  method, which no form can issue.
- `docs/api.md` told clients to send `Content-Type: application/octet-stream`
  when writing a file — the value the CSRF filter rejects, so anyone following
  the page got a 415 on every write. It now documents `application/json`, and
  415 appears in both error-reference tables.

## [0.3.0] - 2026-07-31

A CSRF fix, and three cases where the API now behaves the way its
documentation already described. Found by an Appverse review of v0.2.0.

Three breaking changes, all in what job and cluster endpoints return. Clients
that branch on `status`, or that treat an empty `accounts`/`queues` list as
meaningful, need updating. Sites upgrading without custom clients are
unaffected.

### Changed

- **BREAKING:** job reads return the portable `ood_core` `status` vocabulary
  (`queued`, `queued_held`, `running`, `suspended`, `completed`) rather than
  the raw scheduler word. A queued Slurm job previously reported `pending`,
  so a client branching on the documented `queued` never matched — including
  the polling example in our own API guide. The scheduler's own word is still
  available as a new `native_state` field, which is what distinguishes
  `cancelled`, `timeout`, and `failed`, since `ood_core` flattens all three
  into `completed`.
- `accounts` and `queues` return **501** on adapters that cannot answer them.
  `ood_core`'s base adapter returns an empty list for these two where it
  raises for the others, so a PBS, LSF, or SGE site got `200 []` — impossible
  to tell from "you genuinely have no accounts". An empty list now means only
  the latter.
- A scheduler that cannot be reached returns **503** from job submit, cancel,
  hold, and release, matching what the read endpoints already did. All four
  previously reported an outage as 422, so the same `slurmctld` failure gave
  503 on a read and 422 on a write.

### Fixed

- **CSRF on state-changing requests.** With OOD's default session-cookie
  authentication a browser attaches the session to a cross-origin form post,
  so an attacker's page could drive writes, deletes, and job submissions as a
  logged-in user. `POST`, `PUT`, `PATCH`, and `DELETE` requests carrying a
  body now require `Content-Type: application/json`, which no HTML form can
  send. Requests carrying an `X-OOD-API-Token` are exempt, that header being
  equally unforgeable cross-origin.
- The environment endpoint no longer reports a false reason. A variable
  refused by the credential-name deny pass was reported as "not in allowlist"
  even when the site had explicitly allowlisted it.

## [0.2.0] - 2026-07-31

Security and correctness fixes across the REST and MCP surfaces, found by
adversarial review of every source file and verified against a live OOD 4.2.3
deployment with Slurm and Keycloak. One breaking change: application tokens
move to their own header.

Sites not using `OOD_API_APP_TOKENS` can upgrade without changes.

### Changed

- **BREAKING:** application tokens are sent in an `X-OOD-API-Token` header
  instead of `Authorization: Bearer`. Apache consumes `Authorization` for the
  IdP's JWT when configured for bearer validation, so the two could not be
  used together. **If your site sets `OOD_API_APP_TOKENS=true`, every client
  must move the token to the new header.** There is no fallback.
- Application tokens now guard the MCP endpoint. `/mcp` is mounted outside the
  Sinatra app's filters and previously served the full toolset with no
  app-token check while `/api/v1/*` enforced one.
- `hold_job` and `release_job` return the `ood_core` status vocabulary
  (`queued_held`, `queued`) rather than the adapter-specific `held` and
  `released`.
- Dependencies: `mcp` 0.12.0 → 1.0.0, `ood_core` 0.30.2 → 0.31.1.

### Security

- **File operations could reach sensitive paths in the user's home.** `~/.ssh`,
  the app's own token store, `~/.config/systemd/user` and shell init files are
  now denied on read and write, on both surfaces. Three bypasses of the first
  version of that control were found and closed: symlinks, hardlinks, and
  recursive delete sweeping denied children beneath an allowed parent.
- **Arbitrary HTTP response injection at `/mcp`.** The `mcp` 0.12.0 transport
  returned a non-object request body verbatim, which Rack served as a
  `[status, headers, body]` triple — letting a caller choose the status, every
  header, and the body, from the authenticated OOD origin. Fixed upstream in
  1.0.0; requires both a valid JWT and app token to reach, so it is not a path
  in from outside.
- **`SLURM_JWT` and similar credentials leaked through the environment
  endpoint.** It holds a bearer token for `slurmrestd` and matches the allowed
  `SLURM_` prefix, so it was disclosed under any site policy. Credential-shaped
  names are now denied regardless of the allowlist.
- **The token store destroyed credentials under ordinary concurrent use.** The
  Dashboard plugin and the API wrote the same file non-atomically from
  different processes; a torn read was treated as "no tokens" and written back
  as an empty array. Writes are now atomic and mutations take a cross-process
  lock. Revocation was separately a lost update, so a revoked token kept
  authenticating while the UI reported success.
- **A path that is not valid UTF-8 crashed the path check itself**, before the
  allowed-roots and deny-list checks reached a verdict.
- **Audit records could be lost or forged.** An invalid UTF-8 byte in any
  logged value raised inside the logger, discarding the record and turning a
  clean 4xx into a 500 — so filesystem probing left no trace. Control
  characters in caller-supplied values are escaped so a path cannot forge a
  log line.
- Oversized request bodies are rejected after authentication, so an
  unauthenticated caller can no longer learn the configured write limit.

### Fixed

- **`hold`, `release` and `cancel` reported success for jobs that do not
  exist**, returning a status never derived from the scheduler. `ood_core`
  deliberately swallows "Invalid job id specified" on all three, so all three
  now confirm the job exists first.
- **A scheduler outage was reported as a deleted job.** `GET /jobs/:id` mapped
  every adapter error to 404, and the documented polling advice is to treat
  404 as "finished, stop polling". Outages now return 503.
- **A successful submission could be reported as a failure** when the
  follow-up status lookup failed — the message most likely to make a client
  retry and submit a duplicate.
- **`read_file` returned a 500 for any file containing a non-ASCII byte**, on
  MCP, including files it had just written. The PUN starts with no `LANG`.
- **Reading a FIFO or device node blocked a worker indefinitely.** Only
  regular files are read now.
- Scheduler adapter errors no longer surface as blank 500s: unsupported
  operations return 501, adapter failures 503. Handler errors have
  application-wide default statuses, so a route missing a rescue degrades
  correctly rather than 500ing.
- A full disk or exceeded quota returns 507 from every file-creating
  operation, not only writes.
- Malformed input returns 400 rather than 500: non-object JSON bodies, array
  or hash query parameters, null bytes in paths, non-numeric `wall_time`, and
  invalid `max_size`.
- Job submission validates `output_path` and `error_path`, which previously
  bypassed the deny-list entirely.
- `multi_json` is pinned to 1.19.1; the `mcp` upgrade pulled a release
  requiring Ruby 3.2, breaking `bundle install` on the Ruby 3.0 and 3.1 that
  OOD 3.x ships.

### Documentation

- Installation moved out of the README into `docs/installation.md`;
  `CONTRIBUTING.md` added.
- The user guide is now a site template, with a **Connect an AI assistant**
  quick start, a before-you-publish checklist, a sync marker for tracking
  drift from upstream, and a Getting Help section for a local contact.
- Corrections to guidance that was wrong rather than merely stale: the cancel
  endpoint's documented 422 for unknown job ids (that was the
  fabricated-success bug); `sub` recommended as `OIDCOAuthRemoteUserClaim` for
  Keycloak, where another guide forbids it; and the claim that an
  administrator hands you a token when your site has no OAuth discovery — you
  obtain a JWT yourself with a tool such as `oidc-agent`.
- `test/docs_test.rb` fails CI when a documented number stops matching the
  code — the MCP tool count, the coverage floor, the CI Ruby matrix, the
  app-token header — or when a relative link stops resolving.

## [0.1.0] - 2026-07-12

First release. A REST and MCP API for HPC cluster management via Open OnDemand,
running as a Passenger app under the PUN as the authenticated user.

### Added

- REST API (`/api/v1`) covering clusters, accounts, queues, and cluster info;
  job listing, history, submit, cancel, hold, and release; file list, read,
  write, append, mkdir, touch, and delete; environment variables; and
  site-provided context.
- MCP server at `/mcp` exposing the same surface as 19 tools for LLM and agent
  clients, plus an `ood://context` resource for site policies.
- Authentication that trusts OOD's Apache/`mod_ood_proxy` layer by default,
  with opt-in application-level bearer tokens (`OOD_API_APP_TOKENS`) stored
  per-user at `~/.config/ondemand/tokens.json`.
- Path-traversal-guarded file access confined to allowed roots, allow-listed
  environment-variable disclosure, and audit logging of every operation.
- Configuration via environment variables (cluster path, context path, file
  size limits, env allow-list) with OOD-standard defaults.
- `appverse.yml` declaring explicit Appverse catalog metadata.
- Test suite with SimpleCov coverage (ratcheting minimum) and CI running tests
  across Ruby 3.0–3.3 plus RuboCop.

### Security

- No app-level CORS headers: the app is same-origin behind the OOD proxy, so a
  wildcard would expose a logged-in user's session without protecting anything.
  Cross-origin OAuth discovery documents are handled at the Apache layer.
- API token file is created with mode `0600` atomically, with no window where
  it is readable at the umask default.

[Unreleased]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Sweet-and-Fizzy/ood-api/releases/tag/v0.1.0
