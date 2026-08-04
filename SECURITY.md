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

The specific thing they prevent is **access that outlives the session**. An
agent can be induced to do something unwanted right now; it should not be able
to leave itself a way back in. No SSH key it can add, no shell init file it can
write, no token it can mint, no command it can put on your `PATH`.

Everything below follows from that. Where a control looks over-cautious for a
user who has a shell anyway, this is why.

## What the app can do

Reported plainly, because a deployer should know what they are installing.

It reads, writes, deletes and lists files in the user's space; creates
directories; submits, cancels, holds and releases scheduler jobs through
`ood_core`; reads an allowlisted slice of the process environment; and serves
site policy fragments from `/etc/ood/config/agents.d`. The same operations are
available over REST and as 19 MCP tools.

It makes no outbound network calls, spawns no background processes, loads no
code dynamically, and runs no shell — scheduler interaction goes through
`ood_core`'s adapters, which use argv-form process spawning rather than a shell.

## The controls, and how to check them

Each of these is a claim you can verify. The test files named are the ones that
would fail if the control were removed.

**Path confinement.** File access is confined to `$HOME`, `/tmp` and
`Dir.tmpdir`. Within those, a deny-list refuses shell init files (`.bashrc`,
`.zshrc`, `.profile` and their variants, including `.bash_aliases`), `~/.ssh`,
`~/.local/bin`, `~/.gitconfig` and `~/.config/git`, `~/.netrc`, `~/.forward`,
`~/.pam_environment`, `~/.config/autostart`, `~/.config/systemd/user`, and the
app's own token store.

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

**Authentication.** Apache authenticates every request before it reaches the
PUN; the app trusts that and identifies the user from the OS, not from anything
in the request. Sites may additionally require a per-client application token
(`OOD_API_APP_TOKENS=true`), compared in constant time and stored `0600`.

The MCP endpoint is mounted as a sibling Rack app, outside the REST filters, so
it enforces the token itself — `lib/app_auth.rb` is the single point both
surfaces call. Tests in `test/api_test.rb` assert the two behave identically for
a missing, invalid, empty, or wrong-header token.

**Scheduler interaction.** A job's `output_path`, `error_path` and `workdir` are
validated exactly like any other write, because the scheduler creates those
files as the user. An output path is always supplied, so a `#SBATCH --output=`
directive inside a submitted script cannot redirect the job's output past that
check.

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
operation and the paths involved, including refused authentication attempts.
Values are escaped so a caller-supplied path cannot forge or split a record.
Token values are never logged.

## What this app does not defend against

Stated plainly, because a control you believe in that does not exist is worse
than one you know is missing.

- **No rate limiting.** A looping client can saturate a shared scheduler.
  Apache fronts every request, so a request-rate module there covers the whole
  portal; scheduler-side limits such as `MaxJobCount` bound the damage.
- **No read-only mode.** The read surface cannot be offered without the write,
  delete and job-submission surfaces.
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

- **`Host` validation.** OOD's generated Apache config sets one `ServerName`
  with no alias, so a request carrying any other host is canonicalised before
  it reaches the PUN. The app does not re-check it. A site that adds a
  `ServerAlias`, or fronts the PUN with a different proxy, loses that.
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

## Known unpatched advisory

`excon` carries [GHSA-48rx-c7pg-q66r](https://github.com/advisories/GHSA-48rx-c7pg-q66r)
(medium) — it does not redact some sensitive headers when following redirects.
The fix lands in 1.5.0, which requires Ruby 3.1, and this app supports Ruby 3.0
so that OOD 3.x sites can run it. The advisory stays open until that floor
moves.

It is not reachable here. `excon` arrives transitively through `fog-core` and is
loaded into the process when `ood_core` is required, so it is present — but
nothing in this app constructs an `Excon` connection or makes any outbound HTTP
request, so there is no redirect for the flaw to apply to. That is verifiable
rather than asserted: a socket trip-wire across every endpoint on both surfaces
records zero outbound connections. A site using `ood_core`'s Coder cloud-VM
adapter, which does make such calls, should weigh it differently.
