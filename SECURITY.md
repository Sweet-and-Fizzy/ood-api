# Security

## The threat this app is built around

ood-api runs inside Open OnDemand's per-user NGINX (PUN) as the authenticated
user. It grants no privilege that user does not already have — they can edit any
file it touches, and submit any job it submits, from a shell.

What changes is **who can drive those capabilities**. The same operations are
exposed to an LLM through the MCP endpoint, and an agent reading a file, a job
script, a log, or a webpage can be talked into acting on content that did not
come from the user. That is the case the controls below are built for: not a
malicious user, who needs none of this, but an agent acting on injected input.

The file tools are built to prevent **access that outlives the session**. An
agent can be induced to do something unwanted right now; through the file tools
it should not be able to leave itself a way back in by adding an SSH key,
writing a shell init file, or reading the token store.

**Job submission is outside that guarantee.** A job script is arbitrary code
that the scheduler runs as the user, on a node that at most sites mounts the
same home directory. A submitted script can write `~/.ssh/authorized_keys`, or
anything else the user can, and none of the path controls below apply to what a
running job does. While job submission is available to an agent, treat the
agent as able to run code as the user. What stands between injected input and a
submitted job is, first, the site's choice to enable it at all: job submission
is off in a fresh install. Where it is on, the remaining safeguard is the
client's approval step. `submit_job` is annotated as destructive and
open-world so that MCP clients ask before calling it, and the audit log
records a SHA-256 digest of every submitted script.

Where a file control looks over-cautious for a user who has a shell anyway,
the first paragraph is why.

## What the app can do

Reported plainly, because a deployer should know what they are installing.

It reads, writes, deletes and lists files in the user's space; creates
directories; submits, cancels, holds and releases scheduler jobs through
`ood_core`; reads an allowlisted slice of the process environment; and serves
site policy fragments from `/etc/ood/config/agents.d`. The same operations are
available over REST and as 19 MCP tools.

The app itself makes no outbound network calls, spawns no background processes,
loads no code dynamically, and runs no shell. Scheduler interaction goes through
`ood_core`'s adapters, which use argv-form process spawning rather than a shell.
The jobs it submits are shell scripts and are not constrained by any of this.

## The controls, and how to check them

Each of these is a claim you can verify. The test files named are the ones that
would fail if the control were removed.

**Path confinement.** If the site sets a file allowlist for the Dashboard
(`OOD_ALLOWLIST_PATH`, including in the Dashboard's own env file, or
`allowlist_path` in `ondemand.d`), file access is
confined to exactly those paths, so the API and the file browser follow one
policy. With no allowlist it is confined to `$HOME`, `/tmp` and `Dir.tmpdir`.

Within `$HOME`, a deny-list refuses:

- shell init and logout files (`.bashrc`, `.zshrc`, `.profile` and their
  variants, `.bash_aliases`, `.bashrc.d`, `.config/fish`,
  `.config/environment.d`), and X session files;
- `~/.ssh`, `~/.k5login`, `~/.rhosts`, `~/.forward`, `~/.pam_environment`;
- directories on the default `PATH` (`~/bin`, `~/.local/bin`);
- `~/.gitconfig` and `~/.config/git`;
- anything inside a `.git` directory, and any file named `.git`, in every
  allowed location and not only under `$HOME`. Hooks and config there run
  with every git command;
- startup files for Python (`usercustomize.py`), R (`.Rprofile`), Jupyter and
  VNC, plus `~/.config/autostart` and `~/.config/systemd/user`;
- credential stores (`.netrc`, `.git-credentials`, `.pgpass`, `.my.cnf`,
  `.aws`, `.azure`, `.config/gcloud`, `.kube`, `.docker`, `.gnupg`,
  `.config/gh`, `.config/rclone`);
- the app's own token store.

The list covers the common persistence and credential paths and is not
exhaustive. Other files can run code or hold secrets (editor and application
config, `~/ondemand/dev`, shell history), and a list of names cannot keep up
with them. It is a backstop, not a boundary.

If a denied name is itself a symlink, as when dotfiles are kept in a
repository and linked into place, the file or directory it points at is
denied too.

It is enforced against the requested path, its resolved form, and the
destination a symlink chain actually reaches — following the chain to its end
rather than one hop. Names are compared case-folded, because on macOS and
Windows filesystems `~/.SSH` and `~/.ssh` are the same directory. Hardlinks are
caught by device and inode, since a second name for a denied file resolves to
itself. A recursive delete is refused outright if a denied path lies anywhere
in the tree.

The hard case is a path that does not exist yet: the kernel canonicalises
nothing, so every check runs on the caller's spelling. That is where each
bypass we have found has lived, and most of `test/handlers/files_test.rb` is
aimed at it — dangling symlinks, symlinked parent directories, multi-hop
chains, case variants, hardlink aliases, and traversal. Each of those tests was
written against a specific bypass and verified to fail without its fix.

Checking a path and then opening it resolves the path twice, and in a shared
directory such as `/tmp` another user can replace part of it with a symlink
in between. On Linux the app does not resolve twice. Each file operation
opens the parent directory, asks the kernel where that open directory is,
applies the rules above to that location, and then works on the entry by name
inside it, refusing a symlink that appears in the entry's place. Missing
parent directories are created the same way, one level at a time. Nothing is
created, written, truncated or deleted before the check. FIFOs and device
nodes are refused, since opening one can block a worker indefinitely.
`test/handlers/pinned_files_test.rb` runs these swaps, including a second
process flipping a symlink as fast as it can.

This depends on `/proc/self/fd`, which every Linux host normally has. If a
Linux host is missing it, the file operations are refused with an error that
says so; the app does not fall back to a weaker method. Each start logs which
method is in use (`op=file_access mode=pinned`). Two things remain: a
recursive delete walks the tree by name, and a directory listing reads each
entry's size and dates by name after the names were read safely.

On systems that never had `/proc/self/fd`, which means development on macOS,
the app checks the path before and after the open instead. That narrows the
window without closing it, and is not a deployment configuration.

**What is enabled.** A fresh install serves the read tools only. A site turns
on job submission (`jobs`) and file writes (`files_write`) as groups, removes
individual tools by name, and can switch the REST API or the MCP endpoint off
entirely. A tool that is off is absent from the MCP tool list, not listed and
refused, and its REST route returns 403. Settings that name an unknown group
or tool fall back to read-only and are reported in the PUN log, so a typo
cannot leave a tool on. `test/capabilities_test.rb` covers each of these.

**Authentication.** Apache authenticates every request before it reaches the
PUN; the app trusts that and identifies the user from the OS, not from anything
in the request. Sites may additionally require a per-client application token
(`OOD_API_APP_TOKENS=true`). Only a SHA-256 digest of each token is stored, in a
`0600` file, and digests are compared in constant time, so a copy of the token
file does not yield a working token.

An application token is a per-client credential that can be revoked on its
own. It is not an independent second factor: anyone who holds the user's
session cookie or JWT can open the Dashboard and create one.

State-changing REST requests and all MCP requests are refused when the browser
reports another site as their source (`Origin` or `Sec-Fetch-Site`). REST writes
must also be `application/json`, which an HTML form cannot send. Clients that
are not browsers send neither header and are unaffected. A site that serves a
front end from another origin lists it in `OOD_API_ALLOWED_ORIGINS`.

The MCP endpoint is mounted as a sibling Rack app, outside the REST filters, so
it enforces the token itself — `lib/app_auth.rb` is the single point both
surfaces call. Tests in `test/api_test.rb` assert the two behave identically for
a missing, invalid, empty, or wrong-header token.

**Scheduler interaction.** A job's `output_path`, `error_path` and `workdir` are
validated exactly like any other write, because the scheduler creates those
files as the user. An output path is always supplied, and on Slurm an error
path too, so a `#SBATCH --output=` or `--error=` directive inside a submitted
script cannot redirect the scheduler's own output past that check. This
constrains where the scheduler writes, not what the script does when it runs.

`options.native` — raw scheduler arguments — is **disabled** unless a site sets
`OOD_API_ALLOW_NATIVE=true`. It can express flags that override the paths this
app validates, and no amount of flag matching closes that reliably, so it is
opt-in rather than filtered. Everywhere else in Open OnDemand, `native` comes
from a site administrator's configuration rather than from a request.

A site that does opt in still gets path checking on the flags this app knows:
long and short forms, values given inline or as the next argument, values
bundled onto short flags, and abbreviated long flags, since schedulers accept
any unambiguous prefix and `--out=` means `--output=`. That is defence in
depth, not a guarantee — `native` is argv for whatever scheduler the site
runs, and a flag this app has never heard of can still name a path.

**Credentials in the environment.** The environment endpoint serves an allowlist
(scheduler and module prefixes, plus a fixed set of names), and a deny-pattern
refuses credential-shaped names within it — `SLURM_JWT` is a real Slurm variable
holding a bearer token and sits under an allowed prefix. The deny pass is a
backstop, not the primary control: if it ever fires, the allowlist is too wide,
and the app logs the name so an operator can narrow it.

**Audit trail.** Every operation on both surfaces is logged with the user, the
operation and the paths involved, including refused authentication attempts
and refused cross-site requests. When application tokens are on, each record
carries the id of the token that made the request. A job submission records the
SHA-256 digest and size of its script. Values are escaped so a caller-supplied
path cannot forge or split a record. Token values are never logged.

## What this app does not defend against

Stated plainly, because a control you believe in that does not exist is worse
than one you know is missing.

- **No rate limiting.** A looping client can saturate a shared scheduler.
  Apache fronts every request, so a request-rate module there covers the whole
  portal; scheduler-side limits such as `MaxJobCount` bound the damage.
- **Enablement is per site, not per user or per client.** A capability a site
  turns on is on for everyone who can log in, and for every client and token.
- **Secrets outside the deny-list are readable.** The list names a fixed set
  of paths. A credential kept anywhere else in an allowed directory can be
  read by an agent and end up in a model's context.
- **No per-user or per-group enablement.** As a `sys` app it is available to
  everyone who can log into the portal.
- **Application tokens do not expire.** Revocation is the only control.
- **Revoking a JWT at your IdP has no effect until it expires.** Apache
  validates it statelessly.
- **Recursive delete is a documented, valid call.** The deny-list protects the
  paths above and nothing else.

## What your deployment provides, not this app

Some protections come from the environment rather than from this code. If your
deployment differs from a stock OOD portal, re-check these.

- **`Host` validation.** When `servername` is set in `ood_portal.yml`, OOD's
  generated Apache config redirects any other host to it before the request
  reaches the PUN. With `servername` unset, which is the default, or with
  `server_aliases`, it does not. The app does not check `Host` itself. Every
  request still needs a credential for the portal, so a rebinding attack gains
  nothing, but set `servername` if you rely on this.
- **Authentication itself.** The app has no login. It trusts Apache entirely.
- **Job output paths, if you need a hard guarantee.** Slurm's `job_submit.lua`
  can rewrite `std_out` server-side and applies to every submission path, not
  only this one.

## Reporting a vulnerability

Please don't open a public issue. Report it through
[GitHub's private vulnerability reporting](https://github.com/Sweet-and-Fizzy/ood-api/security/advisories/new),
which keeps the report private until a fix is published.

Include the version or commit you tested, what you did, and what happened. A
reproduction against a running deployment is far more useful than a static
reading of the code — several findings in this project's history looked real in
source and were not, and several looked minor until exercised.

Fixes go to the latest release. There are no long-term support branches.
