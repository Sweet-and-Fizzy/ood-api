# Contributing to ood-api

Contributions are welcome at any level, from a one-line bug report to a new
scheduler adapter. This document covers how to get set up and what the project
expects of a change.

## Ways to help that aren't code

- **Test on your cluster.** ood-api is verified on Slurm and OOD 4.2.3; reports
  from PBS Pro, LSF, Torque, or SGE sites are the single most useful thing right
  now. Even "it worked" is worth an issue.
- **Expand scheduler coverage upstream.** Account discovery, queue listing,
  cluster info, and job history are Slurm-mostly because of what
  [`ood_core`](https://github.com/OSC/ood_core) implements per adapter. Adding
  `queues` or `accounts` to the PBS or LSF adapter there benefits every ood-api
  site on that scheduler.
- **Share agent context.** If you write useful `/etc/ood/config/agents.d/`
  files, share them — site policy expressed well is hard to write from scratch.
- **Report bugs or request features.**
  [Open an issue](https://github.com/Sweet-and-Fizzy/ood-api/issues).

## Development setup

See [docs/development.md](docs/development.md) for the containerised OOD dev
environment. For unit work you only need Ruby and the bundle:

```bash
bundle install
bundle exec rake test
bundle exec rubocop
```

## Before you open a pull request

CI runs the test suite across Ruby 3.0–3.3 plus RuboCop, and will fail on any
of the following. Running them locally first is faster than a round trip.

```bash
bundle exec rake test      # 0 failures
bundle exec rubocop        # 0 offenses
```

**Tests.** New behaviour needs a test. Bug fixes should include a test that
fails before the fix — several bugs in this codebase were originally "fixed"
against a mistaken diagnosis, and a failing-first test is what catches that.
Confirm the test fails for the *right reason*: revert the fix, watch it fail,
restore it. A test written after the fact often passes against the broken code
too, which makes it worse than no test at all.

**What the unit suite cannot tell you.** The suite mocks the scheduler
adapter, so it verifies our code against what we *believed* `ood_core`, the
kernel, and the PUN environment do. Where that belief is wrong, the mock
encodes the same mistake and the tests agree with the bug. Real examples, all
of which passed a green suite:

- `ood_core` deliberately swallows "Invalid job id specified" on hold, release
  and delete, so `hold` on a nonexistent job returned `200 queued_held`.
- The PUN starts with no `LANG`, making `Encoding.default_external` US-ASCII,
  so `read_file` returned a 500 for any file containing an accent.
- Reading a FIFO blocks in `read(2)` forever and wedges the worker.
- A full disk raised `Errno::ENOSPC` straight out of `touch`/`mkdir` as a 500.

So for anything touching the scheduler, the filesystem, encodings, or the MCP
transport, exercise it against the dev container as well
([docs/development.md](docs/development.md)) and say in the PR what you
actually ran and what you saw. A finding that has not been reproduced against
a running system is a hypothesis.

**Docs are tested where they can be.** `test/docs_test.rb` fails CI when a
documented number stops matching the code — the MCP tool count, the coverage
floor, the CI Ruby matrix, the app-token header name — and when a relative
markdown link stops resolving. Docs drift silently otherwise: we shipped one
guide telling Keycloak sites to use the `sub` claim that another guide
explicitly forbids. If you add a claim with a single source of truth in the
repo, assert it there. Claims that need a live cluster cannot be checked from
CI and are deliberately out of scope.

**Coverage.** The suite enforces a line-coverage floor (currently 91%) when
`COVERAGE_ENFORCE=1` is set, which CI does. Don't lower the floor to make a
change pass. Note that a plain `bundle exec rake test` reports a *higher*
figure than the enforced run, because enforcement tracks a wider set of files —
so run it the way CI does before you push:

```bash
COVERAGE_ENFORCE=1 bundle exec rake test
```

Headroom is thin. Adding error branches without tests for them is the usual
way this goes red.

**Ruby 3.0 compatibility.** OOD 3.x ships Ruby 3.0, so the code and the
lockfile must stay installable there. `.rubocop.yml` targets 3.0 and several
gems are pinned below their latest versions for this reason — check the
comments in the `Gemfile` before bumping anything.

**Both surfaces.** Most functionality is exposed twice, as a REST route in
`app/api.rb` and an MCP tool in `app/mcp_tools/`. A change to a handler usually
needs to be reflected in both, and both need tests. Note the two take different
parameter shapes — REST nests under `script`/`options`, MCP is flat.

**Docs.** If you change a route, a tool, a parameter, or an error code, update
`docs/api.md`. If you change something an operator configures, update the
README. Stale examples are worse than missing ones.

## Code conventions

RuboCop is the arbiter for style; run it rather than reading a list. A few
things it doesn't capture:

- **Handlers raise, routes translate.** `app/handlers/` raises the typed errors
  in `app/handlers/errors.rb`; `app/api.rb` maps those to HTTP status codes.
  Handlers should not know about HTTP.
- **Adapter calls go through `Handlers.with_adapter`.** `ood_core` adapters
  raise from three unrelated exception hierarchies, and rescuing only
  `OodCore::JobAdapterError` lets the others escape as unexplained 500s. The
  wrapper exists so that gap can't be reintroduced.
- **Every operation is audited.** Wrap state-changing work in
  `Handlers::Audit.log` so it appears in the PUN log with user, source, and
  outcome.
- **Comments explain why, not what.** The non-obvious constraints — why there
  are no CORS headers, why the token file is written via `rename`, why app
  tokens use their own header — are the ones worth writing down.

## Security issues

Please don't open a public issue for a vulnerability. Report it through
[GitHub's private vulnerability reporting](https://github.com/Sweet-and-Fizzy/ood-api/security/advisories/new),
which keeps the report private until a fix is published.

This app runs as the authenticated user inside OOD's PUN and exposes file and
job operations to LLM clients, so the areas most worth scrutiny are path
handling in `app/handlers/files.rb`, authentication in `lib/app_auth.rb`, and
anything that reaches a scheduler. See the README's
[SECURITY.md](SECURITY.md) for the current model and its
known gaps.

## Community

This app is part of the
[OOD Appverse](https://openondemand.connectci.org/affinity-groups/ood-appverse).
Join the Appverse Affinity Group to connect with other contributors.
