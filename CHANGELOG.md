# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
