# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- Removed the app-level wildcard CORS headers and the catch-all `OPTIONS`
  handler. The app is served same-origin under the OOD proxy, so the wildcard
  granted cross-origin scripted access without protecting anything. Cross-origin
  OAuth discovery documents are handled at the Apache layer.
- Token storage now creates `tokens.json` with mode `0600` atomically instead
  of writing then `chmod`-ing, closing a brief window where the file was
  readable at the umask default.

### Added

- `appverse.yml` declaring explicit Appverse catalog metadata (software,
  app_type, maintainer) instead of relying on `manifest.yml` inference.
- SimpleCov test coverage measurement with a ratcheting minimum, plus tests
  covering the MCP server assembly and `/mcp` mount (previously untested).
- Continuous integration running the test suite (Ruby 3.0–3.3) and RuboCop on
  pushes and pull requests, with coverage enforcement.

### Changed

- Applied RuboCop autocorrect across the codebase and documented the remaining
  intentional exceptions in `.rubocop.yml`.
