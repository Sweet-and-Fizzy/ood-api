# Security Policy

## Reporting a vulnerability

Please don't open a public issue. Report it through
[GitHub's private vulnerability reporting](https://github.com/Sweet-and-Fizzy/ood-api/security/advisories/new),
which keeps the report private until a fix is published.

Include the version or commit you tested, what you did, and what happened. A
reproduction against a running deployment is far more useful than a static
reading of the code — several findings in this project's history looked real in
source and were not, and several looked minor until exercised.

## Supported versions

Fixes go to the latest release. There are no long-term support branches.

## What this app is

ood-api runs inside Open OnDemand's per-user NGINX (PUN) as the authenticated
user, so it grants no privilege that user does not already have. What changes is
who can drive those capabilities: file and job operations are reachable over
HTTP and by an LLM through the MCP endpoint.

The areas most worth scrutiny:

- **Path handling** — `app/handlers/files.rb`. Access is confined to `$HOME`,
  `/tmp`, and `Dir.tmpdir`, with a deny-list covering `~/.ssh`, the token store,
  `~/.config/systemd/user`, and shell init files. Enforced against both the
  requested and resolved path, and by device+inode so a hardlink cannot alias
  around it.
- **Authentication** — `lib/app_auth.rb`, and the filters in `app/api.rb`.
  Apache authenticates upstream; application tokens are an optional second
  factor that must be enforced identically on the REST and MCP surfaces.
- **Anything reaching a scheduler** — `app/handlers/jobs.rb`. Job paths are
  validated like any other write, since the scheduler writes them as the user.

## Known gaps

These are documented rather than fixed, and are listed in the README's
[Security posture](README.md#security-posture) section with mitigations:

- No rate limiting. A looping client can saturate a shared scheduler.
- No read-only mode. The read surface cannot be offered without the write,
  delete, and job-submission surfaces.
- Application tokens do not expire. Revocation is the only control.

Reports about these are welcome if you have a concrete exploit or a mitigation
we have missed, but they are known.

## Known unpatched advisory

`excon` carries [GHSA-48rx-c7pg-q66r](https://github.com/advisories/GHSA-48rx-c7pg-q66r)
(medium) — it does not redact some sensitive headers when following redirects.
The fix lands in 1.5.0, which requires Ruby 3.1, and this app supports Ruby 3.0
so that OOD 3.x sites can run it. So the advisory stays open until that floor
moves, and Dependabot will keep offering the upgrade.

It is not reachable here. `excon` arrives transitively through `fog-core`, which
`ood_core` pulls in for its Coder cloud-VM adapter. Nothing in this app loads
that adapter or makes outbound HTTP, so there is no redirect for the flaw to
apply to. A site using the Coder adapter should weigh it differently.
