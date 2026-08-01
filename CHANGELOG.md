# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Sweet-and-Fizzy/ood-api/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Sweet-and-Fizzy/ood-api/releases/tag/v0.1.0
