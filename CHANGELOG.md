# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **BREAKING:** application-level tokens are now sent in a dedicated
  `X-OOD-API-Token` header instead of `Authorization: Bearer`. Apache owns
  `Authorization` — when configured for bearer validation it consumes that
  header for the IdP's JWT, so an app token had nowhere to go and the two
  modes could not be used together. Clients using `OOD_API_APP_TOKENS` must
  move the token to the new header.
- Application-level tokens now apply to the **MCP endpoint** as well as
  `/api/v1/*`. Previously `/mcp` was mounted outside the Sinatra app's auth
  filter and served the full toolset with no app-token check while REST
  enforced one.
- `hold_job` and `release_job` return `queued_held` and `queued` — the
  `ood_core` status vocabulary the API documents — instead of the
  adapter-specific `held` and `released`.

### Added

- Verified against **Open OnDemand 4.2.3** (Ruby 3.3.10) with real Slurm and
  Keycloak JWT auth: full job lifecycle, queues, cluster info, files,
  environment, and all 19 MCP tools. Recorded in the README's testing table.
- `nginx_stage app` registration step in the install docs. Without it the
  first request to an app OOD has not staged returns an HTML "App has not
  been initialized" page as a 404, which an API client cannot act on.
- Per-IdP guidance for `OIDCOAuthRemoteUserClaim`; the previous blanket
  recommendation of `sub` is wrong for Keycloak (a UUID) and for CILogon
  outside the ACCESS named configuration (an opaque URL).

### Fixed

- File operations no longer reach sensitive paths inside the user's own home:
  `~/.ssh`, `~/.config/ondemand`, `~/.config/systemd/user`, and shell init
  files are denied on both read and write, on REST and MCP. The PUN runs as the
  user and these files remain editable by other means; the point is that an
  agent acting on injected input cannot establish access that outlives the
  session. Three bypasses of an earlier version of this control were found by
  adversarial review and closed:
  - **symlinks** — the check resolves `realpath` and tests both the requested
    and resolved path;
  - **hardlinks** — a second name for a denied inode resolves to itself, so
    name matching cannot see it; denied files are now compared by
    device+inode;
  - **recursive delete** — `DELETE ?recursive=true` on an allowed parent
    (`~/.config`, or `~` itself) swept the denied children beneath it,
    including the API's own token store. Recursive delete now refuses when a
    denied path lies in the tree.
- Token file writes are atomic (temp file + `fsync` + `rename`). `touch` runs
  on every authenticated request and previously wrote in place after
  `O_TRUNC`, so a concurrent reader could observe a partial file; because
  `load_tokens` treats a parse error as "no tokens", that silently 401'd valid
  requests. Measured at ~40% torn reads under concurrent access. Worse than a
  failed read: `touch` then wrote the empty array back, destroying every token
  the user had.
- `touch` no longer raises when the token store is unwritable. A read-only
  `tokens.json` previously turned an authenticated request into a 500.
- Oversized request bodies are rejected *after* authentication. The size check
  ran first, so an unauthenticated caller could learn the configured write
  limit; its message is also no longer file-specific, since the filter guards
  endpoints that involve no file.
- **Arbitrary HTTP response injection at `/mcp` is closed**, by upgrading the
  `mcp` gem from 0.12.0 to 1.0.0. In 0.12.0 the transport returned the parsed
  request body verbatim when that body was valid JSON which is not an object,
  and Rack then treated the return value as a `[status, headers, body]` triple
  — so posting `[200, {"Set-Cookie": "..."}, ["<script>..."]]` served exactly
  that, with attacker-chosen status, headers and body, from the authenticated
  OOD origin. Verified against the running deployment that 1.0.0 refuses it
  with `-32600`.
- A two-byte `/mcp` request (`[]`, `5`, `null`) destructured to a nil status
  and killed the Passenger worker with a 502. Same root cause, also fixed by
  the upgrade.
- `/mcp` no longer buffers unbounded request bodies. It is mounted as a
  sibling Rack app in `config.ru`, so it never saw Sinatra's size filter and
  buffered at roughly 3x the body size in RSS — a large enough POST got the
  worker OOM-killed. 1.0.0 caps the body itself, checking `Content-Length`
  *and* the actual read so a spoofed or chunked length is still bounded. The
  cap is raised from the gem's 4 MiB default to match `MAX_FILE_WRITE`, since
  `write_file` advertises 50 MB and the default would otherwise refuse a
  legitimate write before the handler saw it.
- `ScriptError` escaping the MCP transport no longer kills the worker. It is
  not a `StandardError`, so neither the gem's handler nor its transport caught
  it; REST already had an `error ScriptError` handler and `/mcp` had none.
- **`read_file` no longer returns a bare 500 for any file containing a
  non-ASCII byte.** The PUN starts with no `LANG`, so
  `Encoding.default_external` is US-ASCII and `File.read` tags contents
  US-ASCII; one accented character then made `to_json` raise inside the
  transport, producing a 500 with no JSON-RPC envelope — on a file `write_file`
  had just created successfully. The audit log recorded `status=ok`.
- A null byte in a path returned a `-32603` protocol error from all five MCP
  file tools instead of a tool error; REST already returned 400. All five now
  rescue `ArgumentError`, and `create_directory`/`delete_file` also rescue
  `StorageError`, which their handlers raise.
- `read` refuses anything that is not a regular file. Reading a FIFO blocked
  in `read(2)` indefinitely and wedged the worker — with
  `passenger_min_instances 0` that takes the app down for that user.
- `ENOTDIR`, `ELOOP` and `ENAMETOOLONG` from `write`, `mkdir` and `touch` are
  reported as 400 rather than escaping as blank 500s on REST and `-32603` on
  MCP.
- A non-object `clientInfo` no longer breaks `initialize`. Our callback indexed
  it as a Hash and runs inside an upstream `ensure` with no rescue of its own,
  so the raise discarded an *already successful* initialize and left such a
  client permanently unable to connect. The callback is now type-guarded and
  cannot propagate; 1.0.0 additionally rejects a malformed `clientInfo` with
  `-32602` before it gets that far.
- Migrated from `instrumentation_callback` to `around_request`, which replaces
  it upstream. The audit runs after the wrapped call, because `client` is only
  added to the instrumentation data while the request handler is running.
- Upgraded `ood_core` from 0.30.2 to 0.31.1, which corrects the Slurm state
  map: 0.30.2 spelled the cancelled state `CANCELED`, so the `CANCELLED` that
  Slurm actually emits fell through to `undetermined`. 0.31.1 also matches on
  the first word, so the `CANCELLED by <uid>` form `sacct` returns resolves
  instead of failing the lookup, and its date parsing rescues unexpected values
  rather than raising. Note this does **not** change the "assume successful job
  hold if can't find job id" behaviour that `hold`/`release`/`delete` rely on —
  0.31.1 has the identical code, so the existence check added above is still
  required.
- **A path that is not valid UTF-8 no longer crashes the security check
  itself.** `Pathname#ascend` matches against a regex and raises
  `ArgumentError` on invalid bytes, and `validate_path!` reaches it via
  `find_real_parent` — so a single stray byte crashed out of the allowed-roots
  and deny-list checks *before they reached a verdict*, surfacing as a 500.
  `normalize_path` now rejects invalid encodings and null bytes up front, at
  the one chokepoint every file operation passes through. A malformed job id
  is likewise a 400 rather than a 503 blaming the scheduler.
- **Audit logging can no longer fail the request it is observing.** A value
  that is not valid UTF-8 — an ordinary Linux filename, or a lone surrogate
  from JSON — made `gsub` raise `ArgumentError` inside the logger. That
  replaced a clean 404 with a 500, discarded the audit record entirely, and
  masked the real exception, so a caller probing the filesystem left no trace.
  Values are now scrubbed, a value whose `to_s` misbehaves degrades to
  `<unprintable>`, and `emit` has a backstop that never propagates.
- `Audit.log` records `ScriptError` as well as `StandardError`. Those become
  real HTTP responses, so they were served but never logged.
- U+0085, U+2028 and U+2029 are escaped in audit values. They do not forge a
  record for byte-oriented readers, but a JavaScript-based log viewer treats
  U+2028 as a line terminator. Characters above U+00FF now use `\\uXXXX`,
  since `\\x2028` is ambiguous with `\\x20` followed by `28`.
- `Jobs.get` routes adapter errors through the same wrapper as every other job
  call, so per-adapter exception classes no longer escape as raw 500s.
- **A scheduler that cannot be reached is no longer reported as a missing
  job.** `GET /api/v1/jobs/:id` mapped every adapter error to 404 "Job not
  found", so a `slurmctld` outage told clients a running job did not exist —
  and the documented polling advice is to treat 404 as "finished, stop
  polling". The adapter already distinguishes the two (an unknown id returns
  `Info(status: :completed)`; an unreachable scheduler raises), so the outage
  now returns 503 like every sibling route.
- **`hold`, `release`, and `cancel` no longer fabricate success for a job that
  does not exist.** They returned a hardcoded status that was never derived
  from the scheduler, so `POST /api/v1/jobs/99999/hold` answered
  `200 {"status":"queued_held"}` for an id Slurm rejects. `ood_core`
  deliberately swallows "Invalid job id specified" on all three operations
  ("assume successful job hold if can't find job id"), so the adapter returns
  normally and there is no return value to inspect; all three now confirm the
  job exists first and return 404 otherwise.
- Handler errors have default HTTP statuses registered application-wide, so a
  route that omits a `rescue` degrades to the right code instead of a blank
  500. The per-route rescue lists had drifted: `PUT /files` 500'd on
  `NotFoundError` and `PayloadTooLargeError`, `POST /files` on `StorageError`,
  and `GET /files` on `ValidationError`.
- A full disk or exceeded quota returns **507** from `POST /api/v1/files`
  (both `touch` and `type=directory`), not a blank 500. Only `write` mapped
  these; `EDQUOT` is now handled everywhere too, and reported distinctly —
  a per-user home quota is the case that actually occurs on HPC sites.
- A JSON request body that parses to something other than an object returns
  400. `[1,2,3]`, `null`, and `42` were each indexed like a Hash and raised
  `TypeError`/`NoMethodError` as a 500, as did a `script` or `options` member
  that was not itself an object.
- Query parameters that arrive as an Array or Hash (`?prefix[]=x`,
  `?prefix[k]=x`) return 400 instead of raising `TypeError` inside the
  handler, and a `path` containing a null byte returns 400 rather than
  500ing in `File.expand_path`.
- Token store mutations are serialised with an exclusive lock across
  processes. Every operation was an unlocked read-modify-write of one shared
  JSON array, so a revoke racing the per-request `touch` was a lost update:
  the revoked credential was written back and kept authenticating while the
  UI reported success. Measured at 25 of 30 trials before the fix. The lock
  uses a sidecar file because `flock` is held against an inode and the atomic
  write replaces the file by `rename`.
- The Dashboard plugin's copy of `ApiToken` received the atomic-write and
  unwritable-store fixes that had been applied only to the API's copy. Both
  classes write the same `~/.config/ondemand/tokens.json` from different
  processes, so the non-atomic writer undid the other's fix at runtime.
- `expires_at` and `active?` are removed from the Dashboard plugin's token
  model. Nothing enforced either — `AppAuth` accepts any token whose value
  matches — and the install docs invite operators to hand-write `tokens.json`,
  so a visible expiry field promised a guarantee the API does not make.
- API token names are capped at 100 characters and stripped of control
  characters. The whole token array is rewritten on every authenticated
  request, so an unbounded name was a self-inflicted denial of service.
- `lib/api_token.rb` requires `time` explicitly. It calls `Time#iso8601`,
  which lives in the stdlib rather than core, and worked only because Rack
  happened to load it first.
- A corrupt token file is logged before it is treated as empty. The API's copy
  failed open silently, leaving no trace when a user reported vanished tokens.
- A successful job submission is no longer reported as a failure when the
  follow-up status lookup fails. Previously a `NotImplementedError` from
  `info` surfaced as 501 "submit not supported" *after* the job was queued —
  the message most likely to make a client retry and submit a duplicate.
- Audit values escape all C0 control characters and DEL, not just newline,
  carriage return, and tab. A raw ESC previously reached the log, giving
  anyone tailing it an ANSI-injection vector.
- Scheduler adapter errors no longer surface as blank 500s. Adapters raise
  from three unrelated exception hierarchies — `OodCore::JobAdapterError`,
  per-adapter classes such as `Slurm::Batch::Error` (a plain `StandardError`),
  and `ScriptError` descendants like `NotImplementedError` — and only the
  first was rescued. Unsupported operations now return **501**; adapter
  failures return 503 with the underlying message.
- `max_size` on file reads is validated. A negative value previously raised an
  unrescued `ArgumentError` (500) and a non-numeric coerced to `0`, silently
  returning an empty body. Both now return 400.
- A large `PUT` sent without an explicit `Content-Type` returned a blank 500:
  Rack parsed the body as form data and exceeded its own 4 MB query limit
  before the route's size check ran. Oversized bodies are now rejected with
  413 on `Content-Length` alone.
- A caller-supplied path containing a newline could previously split an audit
  record and forge additional `ood_api_audit` lines.
- Documentation corrections: 413 applies to writes only (an oversized read
  returns 400), the undocumented `touch` parameter on `POST /api/v1/files`,
  a broken README anchor, and the differing parameter shapes between the
  REST and MCP `submit_job` surfaces.

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

[Unreleased]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Sweet-and-Fizzy/ood-api/releases/tag/v0.1.0
