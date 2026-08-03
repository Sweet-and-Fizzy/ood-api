# OOD API

## Overview

OOD API lets your users submit jobs, manage files, and monitor their HPC
cluster without a browser or SSH access. It installs as an Open OnDemand app
and exposes the same operations through two interfaces: a REST API for
scripts, and an MCP server so an AI assistant can do the work conversationally.
Every request runs as the authenticated user, through OOD's existing per-user
process model.

**What people can do with it:**

| | |
|---|---|
| **A researcher with Claude Desktop** | "What happened to my jobs overnight?" — the assistant lists their queue, reads the failed job's stderr, and submits a corrected script. No terminal. |
| **A lab's analysis pipeline** | A Python script authenticates with a JWT, submits a chain of dependent jobs (each starting only after the previous one succeeds), and polls for completion — no SSH keys to distribute or rotate. |
| **A CI runner** | A push to a repo triggers a benchmark job on the cluster, which reports its result back — using a revocable token rather than a shared account. |
| **A group's dashboard** | A web app shows queue depth, allocation usage, and running jobs for a research group — each viewer sees only what their own account can access, since the dashboard queries the API using their identity, not a shared one. |
| **A site operator** | Drops a markdown file in `agents.d/` stating local policy — which partitions to use, which accounts to charge — and every AI client reads it before acting. |

It is a headless API with no end-user UI, though an optional Dashboard plugin
adds a token management page at `/settings/api_tokens`.

This README is for administrators evaluating the app. The guides:

| | |
|---|---|
| [Installation](docs/installation.md) | Deploy it: install, configure auth, register, verify, troubleshoot |
| [User Guide](docs/user-guide.md) | For your users: authenticate, call the API, use the MCP tools |
| [REST API](docs/api.md) | Endpoints, auth, errors, examples, application tokens |
| [MCP Authentication](docs/mcp-auth.md) | Point an MCP client at your site, with or without OAuth discovery |
| [Development](docs/development.md) | Local dev container |
| [Contributing](CONTRIBUTING.md) | Conventions, testing, how to submit a change |

## Before you evaluate

Three things worth knowing before you read further.

**Maturity.** v0.4.0. Verified against OOD 4.2.3 with Slurm, and running at a
small number of sites — see [Testing](#testing) for the current list. Treat it
as early software.

**Scheduler support is uneven.** Job submission, monitoring, cancellation, and
file operations work through [`ood_core`](https://github.com/OSC/ood_core), OOD's
scheduler adapter layer, on any adapter (Slurm, PBS, LSF, Torque, SGE). But
account discovery, queue listing, cluster utilization, and job history are
Slurm-mostly:

| Capability | Slurm | PBS Pro / LSF / Torque / SGE |
|---|---|---|
| Jobs: submit, list, get, cancel, hold, release | Yes | Yes |
| Files, environment, site context | Yes | Yes |
| Accounts, queues, cluster info, job history | Yes | Mostly unsupported — returns `501` |

If you don't run Slurm, roughly a quarter of the surface will return
`501 not_implemented`. See [Compatibility & Maintenance](#compatibility--maintenance)
for the per-adapter detail.

**What this app can do as the user.** It runs inside OOD's per-user NGINX (PUN)
as the authenticated user, so it can do what that user can do. Most of that
surface is read-only ([What it exposes](#what-it-exposes) has the full list).
Three operations destroy or overwrite data, and cannot be undone through the
API:

- **Cancelling a job**, losing whatever compute it had accumulated.
- **Writing a file**, replacing its contents.
- **Deleting a file or directory**, recursively if asked.

Submitting jobs is not destructive but does consume allocation, so a client in
a loop costs real money.

All of this, reads plus the destructive operations above, is reachable by an
LLM through the MCP endpoint, not just a person clicking through the dashboard.
It is constrained by an allowlist of path roots, a deny-list covering `~/.ssh`,
shell init files, and the app's own token store, an environment-variable
allowlist, and audit logging of every operation. Two gaps have no fix inside
the app. **No rate limiting** means a looping agent can saturate a scheduler
your other users share. **No read-only mode** means you cannot offer the read
surface without also offering write, delete, and job submission.
[Security posture](#security-posture) covers both gaps, including what you can
do about them at the Apache and scheduler layers.

## Architecture

ood-api adds no new trust boundary. It sits inside the machinery OOD already
uses to run apps as the logged-in user.

```
   curl · scripts · CI                Claude · Cursor · MCP clients
              │                                    │
              └─────────────────┬──────────────────┘
                                │  Authorization: Bearer <jwt>
                                ▼
        ┌──────────────────────────────────────────────┐
        │  Apache — mod_auth_openidc                   │
        │  validates the JWT against your IdP          │
        └──────────────────────┬───────────────────────┘
                               │  REMOTE_USER = alice
                               ▼
        ┌──────────────────────────────────────────────┐
        │  alice's PUN — OOD's per-user process        │
        │                                              │
        │      ┌────────────────────────────────┐      │
        │      │  ood-api                       │      │
        │      │  /api/v1/*  and  /mcp          │      │
        │      │            │                   │      │
        │      │            ▼                   │      │
        │      │  clusters · jobs · files · env │      │
        │      └────────────────────────────────┘      │
        └──────────────────────┬───────────────────────┘
                               │  ood_core
                               ▼
              Slurm · PBS · LSF · Torque · SGE
```

The consequence: a request can only ever do what that user could already do
from a shell. See [Security posture](#security-posture) for the limits placed
on top of that.

## Requirements

- **Open OnDemand 3.x or 4.x**, verified through 4.2.3 (Ruby 3.3.10). The
  optional Dashboard plugin needs 4.0+.
- **An OIDC identity provider that issues JWTs**, with a JWKS endpoint Apache
  can reach. This is the part most likely to constrain you — see
  [installation](docs/installation.md#2-configure-authentication).
- Nothing on your compute nodes. The app runs on the OOD host and reaches
  clusters through `ood_core`, and `mod_auth_openidc` already ships with OOD.

## Installation

Clone the app, configure Apache to accept bearer tokens, register it with
NGINX, verify. Full walkthrough in
**[docs/installation.md](docs/installation.md)**.

How long it takes depends almost entirely on your identity provider. If it
already issues JWTs and you know which claim maps to your usernames, it is a
short job. If not, expect to spend your time there rather than on the app.


## What it exposes

Available on both surfaces — as a REST endpoint and as an MCP tool — except
where noted.

- **Clusters** — list configured clusters and their details, plus queues,
  accounts, and current utilization.
- **Jobs** — submit (optionally with dependencies), list, get, cancel, hold,
  release, and query history.
- **Files** — list, read, write, append, make directories, and delete,
  confined to allowed roots. `touch` is REST-only; there is no MCP tool for it.
- **Environment** — list and read allowlisted variables.
- **Site context** — operator-authored markdown from `agents.d/`, so an agent
  can read local policy before acting. Exposed as an MCP *resource* rather than
  a tool.

Full detail: **[REST reference](docs/api.md)** for endpoints, request bodies,
and error codes; **[User Guide](docs/user-guide.md#32-available-tools)** for the
MCP tools and their parameters.

Note the two surfaces take different parameter shapes — REST nests under
`script` and `options`, MCP is flat.

Every operation on either surface writes a `key=value` audit line to the PUN
log with the calling user, the parameters, and the outcome.

### Site context

`ood://context` serves whatever markdown you place in
`/etc/ood/config/agents.d/` to MCP clients as a *resource* — read-only context
a client fetches, as opposed to a *tool* it calls to act. It is **advisory**: a
well-behaved client reads it before acting, but nothing enforces it. Use it to
state site policy ("submit test jobs to the `debug` partition"), not as a
security control.


## Security posture

The app runs in the user's PUN as that user, so it grants no new privilege —
everything it can do, the user could already do from a shell. What changes is
*who can drive it*: submit and cancel jobs, and read, write, and recursively
delete files, all reachable by an LLM through the MCP endpoint.

**Constraints.**

- **Allowed roots.** File access is confined to `$HOME`, `/tmp`, and
  `Dir.tmpdir`.
- **Denied paths within those roots.** `~/.ssh`, `~/.config/ondemand` (the
  token store), `~/.config/systemd/user`, `~/.local/bin`, `~/.config/git`,
  `~/.config/autostart`, shell init files, `~/.gitconfig`, `~/.netrc`,
  `~/.forward`, and `~/.pam_environment` are refused on both read and write —
  including reached via symlink or hardlink. Recursive delete refuses outright
  when one lies in the tree.
- **Regular files only.** Reading a FIFO or device node is refused rather than
  blocking the worker.
- **Allowlisted environment variables**, with credential-shaped names
  (`*_TOKEN`, `*_JWT`, `*SECRET*`) denied regardless of the allowlist.
- **Size caps** on reads and writes, via `OOD_API_MAX_FILE_READ` and
  `OOD_API_MAX_FILE_WRITE`.
- **Audit logging** of every operation to the PUN log, with control characters
  escaped so a caller-supplied path cannot forge a record.

The deny-list is not about stopping the user: they can still edit any of those
files from a shell. It is about ensuring an agent acting on injected input
cannot establish access that outlives the session.

**What is not constrained** — worth knowing before you deploy:

- **No rate limiting.** A looping agent can hammer your scheduler through
  `squeue`/`sacct`, and nothing in the app throttles it. Because Apache fronts
  every request, a request-rate module there covers the whole portal —
  `mod_qos` or `mod_evasive`, or a reverse proxy such as nginx with
  `limit_req`. The bundled `mod_ratelimit` throttles bandwidth rather than
  request rate and will not help. Scheduler-side limits such as `MaxJobCount`
  or per-association QOS limits bound the damage rather than the rate, and are
  worth having anyway. We have not tested any of these configurations, so
  verify whichever you choose on your own site.
- **No read-only mode.** You cannot disable the write, delete, or job-submission
  surface while keeping the read surface. `OOD_API_MAX_FILE_WRITE=0` rejects
  file writes with a 413, which is a partial stand-in, but it does not touch
  delete, mkdir, or job submission — do not mistake it for a read-only switch.
- **No per-user or per-group enablement.** As an OOD `sys` app it is available
  to everyone who can log into the portal. Restricting it means not installing
  it, or removing it from `/var/www/ood/apps/sys`.
- **Recursive delete is a documented, valid call.** `DELETE
  /api/v1/files?path=…&recursive=true` and the `delete_file` MCP tool will remove
  a directory tree. The deny-list protects the paths listed above and nothing
  else.
- **`options.native` is off unless you enable it.** It is raw argv for the
  submit command, so a caller can select any flag the scheduler accepts —
  including ones that override the paths this API validates. Every other part
  of Open OnDemand takes `native` from a site admin's config rather than from a
  request, and the usual reasoning ("the user has a shell anyway") does not
  hold for an agent whose only access is this API. Set
  `OOD_API_ALLOW_NATIVE=true` if your site needs it, and note that job paths
  are then only as constrained as your scheduler makes them.
- **App tokens do not expire.** They are valid until revoked in the Dashboard.
- **Revoking a JWT at your IdP has no effect until it expires.** Apache
  validates the signature and expiry statelessly; it never asks the IdP whether
  the token is still good. Short token lifetimes are the only mitigation
  available today.

## Testing

We're actively looking for sites to test ood-api on different schedulers and OOD versions. If you try it, please let us know how it goes — even a quick "it worked on PBS" is helpful.

| Site | OOD Version | Scheduler | Status |
|------|-------------|-----------|--------|
| University of Kentucky | 3.x | Slurm | Tested |
| Wake Forest University | 4.1 | Slurm | In progress |
| Demo container (`travertosc/ood-demo`) | 4.2.3 | Slurm 22.05.9 | Tested — full REST + MCP surface, Keycloak JWT auth |

The 4.2.3 run covered the whole job lifecycle (submit, get, list, hold,
release, cancel), queues, cluster info, file and environment operations, and
all 19 MCP tools, on Ruby 3.3.10 with `mod_auth_openidc` validating Keycloak
JWTs. `accounts` returns 503 on a cluster without `slurmdbd`, which is
expected — `sacctmgr` needs an accounting store.

The demo image ships OOD alone: Slurm was installed into the container as
RPMs and Keycloak run alongside it as a separate container, so pulling the
image by itself does not reproduce that environment.

To verify a deployment, see
[step 5 of the installation guide](docs/installation.md#5-verify). To work on
the code, see [Contributing](CONTRIBUTING.md) and
[docs/development.md](docs/development.md).

## Known Limitations

- Application tokens are a second factor and never stand alone — a request must also satisfy Apache, with either a JWT or a session cookie
- PUN cleanup cron runs every 2 hours by default — long-running API workflows may need this adjusted
- Dashboard plugin requires OOD 4.0+
- MCP transport runs in stateless mode — server-initiated notifications are not supported (tool list is static, so this has no practical impact)
- Job history, hold/release, and dependencies are scheduler-dependent — not all schedulers support all features
- Account discovery, queue listing, cluster info, and historic jobs are only fully supported on Slurm — other schedulers return `501 not_implemented`. See the scheduler table under [Before you evaluate](#before-you-evaluate). Contributions to expand adapter coverage in `ood_core` would benefit all ood-api sites
- No rate limiting, and no read-only mode — see [Security posture](#security-posture)
- Historic job listings are **filtered to the authenticated user** (`job_owner` must match); the raw accounting API may return broader data on some schedulers
- Audit log output goes to stderr (PUN error.log) — no dedicated log file or rotation beyond OS logrotate

## Compatibility & Maintenance

ood-api uses [`ood_core`](https://github.com/OSC/ood_core) (`~> 0.24`, same constraint as the OOD Dashboard) for all scheduler operations. We call only the public adapter interface.

| Adapter method | Used by | Supported adapters (ood_core 0.31) |
|---|---|---|
| `submit`, `delete`, `info`, `info_where_owner` | Jobs | All |
| `hold`, `release` | Hold/release | Most (Slurm, PBS, LSF, Torque, SGE, etc.) |
| `accounts` | Account discovery | Slurm, HTCondor, PSI/J |
| `queues` | Queue discovery | Slurm |
| `cluster_info` | Cluster utilization | Slurm, PBS Pro, HTCondor, PSI/J |
| `info_historic` | Job history | Slurm |

Operations an adapter cannot perform return **501 `not_implemented`**
uniformly. `ood_core`'s base adapter returns an empty list for `accounts` and
`queues` where it raises for the others, so the API detects that case and
reports it as 501 too — an empty list therefore means you genuinely have none,
never "your scheduler cannot answer".

When `ood_core` releases a new version, we review the changelog, run the test
suite against it, and update the table above.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, conventions, and what CI
expects. The most useful contribution right now is **testing on a non-Slurm
scheduler** — PBS Pro, LSF, Torque, or SGE — and
[telling us what happened](https://github.com/Sweet-and-Fizzy/ood-api/issues).

This app is part of the [OOD Appverse](https://openondemand.connectci.org/affinity-groups/ood-appverse). Join the Appverse Affinity Group to connect with other contributors.

## License

[MIT License](LICENSE)

## Acknowledgments

Testing supported by Wake Forest University and the University of Kentucky. The agent context pattern (`/etc/ood/config/agents.d/`) was inspired by Purdue RCAC's [`rcac-mcp`](https://github.com/PurdueRCAC/rcac-mcp). The [CaRCC People Network](https://carcc.org/people-network/) discussion on sandboxing AI agents in HPC environments motivated much of the design.
