# Installing ood-api

Deployment guide for OOD administrators. If you are still deciding whether to
deploy this, start with the [README](../README.md) — it covers what the app
does, what it can reach, and its known limits.

Everything below assumes shell access to the OOD host as an account that can
`sudo`.

## Install

### 1. Clone the repository

```bash
cd /var/www/ood/apps/sys
sudo git clone https://github.com/Sweet-and-Fizzy/ood-api.git
cd ood-api

# Pin to a release (recommended). This guide describes 0.5.0 and later.
# Earlier releases have job submission and file writes on from the start
# and do not read the settings described under "What to enable".
# sudo git checkout v0.5.0

sudo bundle config set --local path vendor/bundle
sudo bundle config set --local without 'development test'
sudo bundle install

sudo chown -R root:root .
```

### 2. Configure authentication

Configure Apache to accept bearer tokens, so API and MCP clients can
authenticate without a browser. Add to `/etc/ood/config/ood_portal.yml`:

```yaml
auth:
  - "AuthType auth-openidc"
  - "Require claim aud:YOUR_OOD_CLIENT_ID"
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://your-idp.example.edu/certs"
  OIDCOAuthRemoteUserClaim: "preferred_username"
```

**The `Require claim aud:` line is not optional.** Apache checks a bearer
token's signature and expiry and nothing else. With `Require valid-user`, a
token your IdP issued to *any* client, for any other service, logs its owner
in to the whole portal, Shell included. Requiring the audience limits bearer
access to tokens issued for Open OnDemand's own client. Use the client ID from
`oidc_client_id` in `ood_portal.yml` (with the bundled Dex it is the portal's
server name). Browser login is unaffected, because the session's ID token
carries the same audience.

**Keycloak sites use `Require claim azp:YOUR_OOD_CLIENT_ID` instead.** A
Keycloak access token carries `aud: account` and names the client in `azp`, so
the `aud:` line above refuses every bearer token, the portal's own included.
Do not require `aud:account`: it accepts tokens from every client in the realm
and breaks browser login. Checked on Keycloak 26.0.8 with Open OnDemand 4.2.5:
with the `azp:` line the portal client's token is accepted, another client's
token gets a 401, and browser login still works.

Whatever the IdP, check the result by presenting a token issued to another
client: it must get a 401. With the bundled Dex, a second client for that
check is one entry under `dex: static_clients:` in `ood_portal.yml`.

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

Restarting `httpd` ends existing browser sessions, so users sign in again.
Afterwards, `grep OIDCOAuth /etc/httpd/conf.d/ood-portal.conf` should show
both settings. If `ood_portal.yml` already had an `oidc_settings` block, add
the two lines to it; a second block with the same name replaces the first.

Your IdP publishes the JWKS address as `jwks_uri` in
`<issuer>/.well-known/openid-configuration`.

That is the whole setup for most sites. Three caveats:

**This changes auth for the whole portal**, not just ood-api — OOD has no
per-app auth config. Browser login still works (`auth-openidc` is a superset of
`openid-connect`), but test in staging. To roll back, remove both blocks, re-run
`update_ood_portal`, and restart `httpd`.

**Your IdP must issue JWT access tokens**, since Apache validates the signature
against the JWKS. Keycloak and Dex do by default. CILogon issues opaque tokens
unless it has configured a token handler for your client, and those cannot be
validated this way — see
[If your IdP issues opaque access tokens](mcp-auth.md#if-your-idp-issues-opaque-access-tokens).

**Set `OIDCOAuthRemoteUserClaim` to a claim your [`user_map_match`][portal-yml]
accepts.** The wrong one authenticates the request and then fails with
`failed to map user`:

| IdP | Claim | Value it yields |
|-----|-------|-----------------|
| Keycloak | `preferred_username` | the username (`sub` is a UUID — do not use it) |
| Bundled Dex | the claim `oidc_remote_user_claim` already names, often `email` | what browser login already maps |
| CILogon via ACCESS | `sub` | the ACCESS ID (`someone@access-ci.org`) |
| CILogon (no named config) | — | `sub` is an opaque URL, unusable for mapping |

#### Optional: application tokens

Skip this unless you want per-client credentials — one token per laptop or CI
runner, each revocable on its own from the API Tokens page, where a JWT is
all-or-nothing.

Set `app_tokens: true` in the app's settings (see [What to enable](#what-to-enable))
and install the Dashboard plugin (OOD 4.0+):

```bash
sudo mkdir -p /etc/ood/config/plugins
sudo ln -s /var/www/ood/apps/sys/ood-api/dashboard-plugin /etc/ood/config/plugins/ood-api
```

Link it rather than copying it. A link lets the token page find the app it
belongs to wherever that is installed; a copy assumes
`/var/www/ood/apps/sys/ood-api`.

Every request to `/api/v1/*` and `/mcp` must then carry `X-OOD-API-Token:
<token>` **in addition to** whatever Apache accepts. The token is never a
credential on its own, and it can be revoked per client. It is not an
independent second factor, since anyone signed in as the user can create one. Its own header is what lets it coexist
with the JWT in `Authorization`. [Restart the PUNs](#restarting-puns); token
management appears at `/pun/sys/dashboard/settings/api_tokens`. The Dashboard
has no menu entry for it, so give users that address or add a link to your
navigation.

If that page 404s, check that every file under `dashboard-plugin/` is root-owned
— OOD skips plugins that aren't, silently. The plugin logs `OOD API plugin
loaded` when it loads; look for it in the user's PUN log,
`/var/log/ondemand-nginx/<user>/error.log`.

**A caveat if your IdP does not issue JWT access tokens** (Google OIDC, and
CILogon unless it has configured a token handler for your client): Apache then
only accepts a browser session cookie, so a script has to carry a cookie copied
from DevTools that expires with the OIDC session — 8 hours by default. Fine
occasionally, poor for anything unattended. See
[the REST API guide](api.md#application-tokens) for the full flow, and
[If your IdP issues opaque access tokens](mcp-auth.md#if-your-idp-issues-opaque-access-tokens)
for the introspection alternative.

Tokens can also be created by hand, by the user whose token it is. This adds
one to the file and leaves the existing ones alone:

```bash
ruby -rjson -rsecurerandom -rdigest -rtime -rfileutils -e '
  file = File.expand_path("~/.config/ondemand/tokens.json")
  FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
  tokens = File.exist?(file) ? JSON.parse(File.read(file)) : []
  token = SecureRandom.hex(32)
  tokens << { "id" => SecureRandom.uuid, "name" => "My Token",
              "token_digest" => Digest::SHA256.hexdigest(token),
              "created_at" => Time.now.iso8601,
              "expires_at" => (Time.now + 90 * 86_400).iso8601 }
  File.write(file, JSON.pretty_generate(tokens), perm: 0o600)
  puts "Your token: #{token}"'
```

### 3. Register the app with NGINX

OOD normally stages an app the first time someone opens it in the browser.
ood-api has no page of its own to open, so nobody stages it by visiting it, and
an API client gets the "App has not been initialized" page as a 404 instead.
Stage it once:

```bash
sudo /opt/ood/nginx_stage/sbin/nginx_stage app \
  --user=<a regular user> --sub-uri=/pun --sub-request=/sys/ood-api
```

Name any ordinary portal account; `root` is refused. If that account has no
PUN running, the command prints an nginx `[emerg]` line and exits 1 although
the config was written. Confirm with
`ls /var/lib/ondemand-nginx/config/apps/sys/ood-api.conf`.

One command per site, not per user — the generated config is shared. Users
whose PUN was already running get the API after their PUN
[restarts](#restarting-puns); everyone else from their first request.

### 4. MCP Endpoint

The MCP endpoint is at `/mcp`. Configure your MCP client to connect via HTTP:

**Claude Code CLI:**

```bash
claude mcp add ood-hpc --transport http https://ondemand.example.edu/pun/sys/ood-api/mcp
```

With a pre-registered client, which the bundled Dex needs, add
`--client-id <id> --callback-port <port>`; see
[MCP Authentication](mcp-auth.md#client-configuration-1).

**Claude Desktop (via mcp-remote):**

```json
{
  "mcpServers": {
    "ood-hpc": {
      "command": "npx",
      "args": ["mcp-remote", "https://ondemand.example.edu/pun/sys/ood-api/mcp"]
    }
  }
}
```

MCP clients authenticate via JWT bearer tokens validated by Apache. This requires the `auth` override in step 2. See [MCP Authentication](mcp-auth.md) for two setup methods: static bearer tokens (minimal config) or automatic OAuth discovery (best UX).

Every limit and restriction applies to **both** surfaces — size limits, the path
allowlist, the sensitive-path deny-list, and the environment-variable allowlist.
MCP is not a way around them. The difference is only in how a refusal is
reported: an MCP tool returns a result marked as an error, REST returns an
HTTP status. See
[Configuration](#configuration) for the settings and
[SECURITY.md](../SECURITY.md) for what they do.

### 5. Verify

```bash
curl -H "Authorization: Bearer <your-jwt>" \
  https://ondemand.example.edu/pun/sys/ood-api/health
```

The response shows the settings in force:

```json
{"status":"ok","rest":true,"mcp":true,"local":false,"tools":["get_cluster","..."],
 "app_tokens":false,"file_access":"pinned","from_environment":[],
 "settings":"/etc/ood/config/apps/ood-api/config.yml (not found)",
 "env":"/etc/ood/config/apps/ood-api/env (not found)","problems":[]}
```

`status` is `ok` when at least one of REST and MCP is served, `disabled` when
the site has switched both off, and `misconfigured` (HTTP 503) when the
settings could not be understood, with the reason under `problems`. A **404
returning an HTML page** titled "App has not been initialized" means step 3
has not been done.

## Configuration

### What to enable

A fresh install is read-only. It can list clusters, accounts, queues, jobs and
files, read file contents, and read the allowed environment variables. Turn on
more in `/etc/ood/config/apps/ood-api/config.yml`:

```yaml
capabilities: [read, jobs, files_write]
disable: [cancel_job]
mcp: true
rest: true
app_tokens: false
```

Everything a site sets for this app lives in that directory, the same place
Open OnDemand keeps settings for its other apps, so nothing in the app's own
checkout is ever edited. The directory takes the name the app is installed
under: installed as `/var/www/ood/apps/sys/api`, the app reads
`/etc/ood/config/apps/api/`. `/health` names the settings file and the env file being read
and says whether each was found; the PUN log names the settings file. The file is plain YAML, must be owned by
root, and must be readable by every portal user.

| Group | Tools |
|-------|-------|
| `read` (always on) | `list_clusters`, `get_cluster`, `list_accounts`, `list_queues`, `get_cluster_info`, `list_jobs`, `get_job`, `list_historic_jobs`, `list_files`, `find_files`, `read_file`, `list_env`, `get_env`, `list_interactive_sessions`, `list_interactive_apps`, `list_software`, `get_quota_and_balance` |
| `jobs` | `submit_job`, `cancel_job`, `hold_job`, `release_job` |
| `files_write` | `write_file`, `create_directory`, `delete_file` |

`disable` removes single tools, including read tools, from whatever the groups
turned on. The tool name covers both surfaces: `delete_file` removes the MCP
tool and makes `DELETE /api/v1/files` return 403. Over REST, creating an empty
file with `POST /api/v1/files?touch=true` counts as `write_file`.

What the site has switched off in the Dashboard stays off here, whatever
the settings above ask for:

| Dashboard setting | Effect here |
|---|---|
| The Files app is not installed (`/var/www/ood/apps/sys/files`) | No file tools at all |
| `download_enabled: false` | `read_file` is off |
| `upload_enabled: false` | `write_file` is off |
| A cluster with `hidden: true` in its metadata | The cluster is not listed and cannot be used, as in the Dashboard's own job tools, which leave hidden clusters out |

`download_enabled` and `upload_enabled` are the Dashboard's own settings: a
top-level key in any `ondemand.d` file, or `OOD_DOWNLOAD_ENABLED` and
`OOD_UPLOAD_ENABLED` in the Dashboard's env file. All four take effect on
running PUNs within a couple of seconds.

`jobs` deserves thought before you enable it. A job script is code that runs
as the user, so an assistant that can submit jobs can do anything the user
can. See [SECURITY.md](../SECURITY.md).

**Settings the app cannot understand turn it off.** An unknown group, tool
or key, a switch that is neither `true` nor `false`, a misspelt `OOD_API_`
variable, a setting written twice, a settings or env file that is not owned
by root or cannot be parsed: any of these makes both REST and MCP answer 503
until it is fixed. So does a file in `ondemand.d` that sets the file
allowlist or the Dashboard switches above and cannot be read. A typo in `disable` would otherwise leave on the
tool it was meant to remove, and the app has no way to tell which that was.
`/health` and the PUN log both say what is wrong.

**Changes to `config.yml` take effect within a couple of seconds, with no
restart.** That makes this the way to switch the app off in a hurry:

```yaml
rest: false
mcp: false
```

Every running PUN stops serving on its next request. The exception is a
setting also given as an environment variable, which wins over the file and
is read only when the PUN starts: if `OOD_API_REST` or `OOD_API_MCP` is set to
`true` anywhere, this switch does nothing until that is removed and the PUNs
restart. `/health` lists the settings held by the environment under
`from_environment`, so check it is empty of those two before relying on the
switch. Each PUN logs the
settings in force when it starts and again whenever they change:

```
ood_api_audit op=capabilities status=ok rest=true mcp=true local=false app_tokens=false tools=get_cluster,get_cluster_info,...
```

### Serving a program on the portal host

Another app in the portal, such as an assistant your site runs itself, can
use the same tools without going through `/mcp`. It starts `bin/mcp-stdio`
from this app's directory as the signed-in user and speaks MCP to it over
standard input and output. This is off until you switch it on:

```yaml
local: true
```

`local` is separate from `mcp`. With `local: true` and `mcp: false`, the
tools are available to programs on the portal host and to no client outside
it except through those programs. A program can pass them on, and an
assistant such as [ood-agent](https://github.com/Sweet-and-Fizzy/ood-agent)
offers them to the user's browser through its chat page, so turn `local` on
knowingly, for programs you have decided to trust with that. The tools offered are the ones you enabled under
[What to enable](#what-to-enable), and every call is in the
[audit log](#audit-log) with `transport=stdio`. There is no application
token here: the program already runs as the user, who can do the same things
from a shell. To switch the app off entirely once this is on, set
`local: false` along with `rest` and `mcp`.

Two things the calling app has to get right. The audit records are written
to the helper's standard error, so the caller must pass that through to its
own, which in a PUN is the user's log; a caller that discards it loses the
records, and one that captures it without reading it will stall the helper.
And the helper takes its settings from `config.yml` and from the environment
it is started with, where a variable wins over the file as it does for the
app itself. `OOD_API_LOCAL` or `OOD_API_CAPABILITIES` set for the PUN, or by
the calling app, therefore cannot be undone from `config.yml`, and `/health`
describes the web app's environment, not the helper's. The helper's own log
line, `op=capabilities`, says what it is serving.

### Where environment variables go

Switches accept `true`, `yes`, `on` or `1`, and `false`, `no`, `off` or `0`.
Group and tool names are matched whatever their case.

Every setting in `config.yml` can also be given as an environment variable
(see the table below), and the limits can only be given that way. Put them in
the env file beside it, `/etc/ood/config/apps/ood-api/env`, one `NAME=value`
per line:

```
OOD_API_MAX_FILE_READ=1048576
```

`pun_custom_env` in `/etc/ood/config/nginx_stage.yml` also works but applies
to every app in the PUN, and wins over the app's env file when both set the
same variable. A variable wins over the same setting in `config.yml`, so a
setting given both ways cannot be switched off from the file. Unlike
`config.yml`, environment variables are read once, when the PUN starts. The
env file must be owned by root and not writable by others, or the app
answers 503. The Dashboard's token page reads `config.yml` and the env file
each time it is shown, while the API reads the env file only when its PUN
starts. So after changing a token setting in the env file, restart PUNs;
until then the page may offer a lifetime the API will shorten on first use.

### Restarting PUNs

```bash
# one user
sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean --force --user=<user>
# everyone
sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean --force
```

Without `--force` the command leaves a PUN with active connections running.
With it, each user's Dashboard and other apps restart too and reload on their
next request; interactive sessions and jobs are not affected. A request in
the first second after a restart can get a 502 while the PUN starts.

### Authentication

| Setting | Location | Description |
|---------|----------|-------------|
| `OIDCOAuthVerifyJwksUri` | `ood_portal.yml` | JWKS endpoint for JWT validation |
| `OIDCOAuthRemoteUserClaim` | `ood_portal.yml` | JWT claim to use as username |
| Dashboard plugin symlink | `/etc/ood/config/plugins/ood-api` | Enables the optional token management UI |

### Session Timeouts

| Component | Default | Configurable |
|-----------|---------|--------------|
| OIDC Session | 8 hours inactivity / 8 hours max | `oidc_session_inactivity_timeout` in `ood_portal.yml` |
| PUN Cleanup | Every 2 hours | Edit `/etc/cron.d/ood` |

### Environment Variables (API)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OOD_CLUSTERS` | No | `/etc/ood/config/clusters.d` | Path to cluster config directory |
| `OOD_API_APP_TOKENS` | No | unset | Set to `true` to require a per-client `X-OOD-API-Token` header in addition to Apache's auth. Also `app_tokens` in `config.yml`. See [application tokens](#optional-application-tokens). |
| `OOD_API_TOKEN_MAX_DAYS` | No | `365` | The longest lifetime an application token may be given, in days. Also `token_max_days` in `config.yml`. A stored expiry beyond it, such as one written into the token file by hand, is pulled back to it the next time the token is used, and tokens created before expiry existed get it the same way. Lowering it shortens existing tokens. |
| `OOD_API_TOKEN_ALLOW_NEVER` | No | unset | Set to `true` to let users create tokens that never expire. Also `token_allow_never` in `config.yml`. |
| `OOD_API_MAX_FILE_READ` | No | `10485760` (10 MB) | Maximum file read size in bytes (REST and MCP `read_file`) |
| `OOD_API_MAX_FILE_WRITE` | No | `52428800` (50 MB) | Maximum request body size in bytes for **every** `/api/v1/*` request, not only file writes — job submission and the MCP envelope are bounded by it too. Lowering it to restrict uploads also caps how large a job script may be. |
| `OOD_API_ENV_ALLOWLIST` | No | See [docs/api.md](api.md#environment-variable-allowlist) | Comma-separated allowlist for env vars endpoint. Entries ending in `*` are prefix matches. |
| `OOD_API_CONTEXT_PATH` | No | `/etc/ood/config/agents.d` | Path to directory containing site-specific agent context files (*.md) |
| `OOD_API_MAX_CONTEXT_BYTES` | No | `262144` (256 KB) | Per-file cap on agent context fragments. A larger file is replaced with a note rather than served. |
| `OOD_API_MAX_CONTEXT_TOTAL_BYTES` | No | `1048576` (1 MB) | Cap across all context fragments together. The per-file cap alone bounds nothing when there are many files. |
| `OOD_API_ALLOW_NATIVE` | No | unset | Set to `true` to accept `options.native` on job submission. It is raw scheduler argv and can override the paths this API validates, so it is off by default — see [the note in the API guide](api.md#submit-job). |
| `OOD_API_CAPABILITIES` | No | `read` | Comma-separated groups to enable: `read`, `jobs`, `files_write`, or `all`. See [what to enable](#what-to-enable). |
| `OOD_API_DISABLE` | No | unset | Comma-separated tool names to remove, for example `cancel_job,list_historic_jobs`. |
| `OOD_API_REST` | No | `true` | Set to `false` to switch off `/api/v1`. |
| `OOD_API_MCP` | No | `true` | Set to `false` to switch off `/mcp`. |
| `OOD_API_LOCAL` | No | `false` | Set to `true` to serve programs on the portal host through `bin/mcp-stdio`. See [serving a program on the portal host](#serving-a-program-on-the-portal-host). |
| `OOD_API_ALLOWED_ORIGINS` | No | unset | Comma-separated origins (for example `https://portal.example.edu`) whose browser requests are accepted in addition to the portal's own. Only needed if a front end on another origin calls this API. |
| `OOD_API_CONFIG_ROOT` | No | `/etc/ood/config/apps/<app>` | The directory holding the app's `config.yml` and `env`. `<app>` is the name the app is installed under. Set it in `pun_custom_env` if you need it; it cannot be set in the env file it locates. |
| `OOD_DOWNLOAD_ENABLED`, `OOD_UPLOAD_ENABLED` | No | `true` | The Dashboard's own switches, read from the PUN environment, the Dashboard's env file, or `download_enabled` and `upload_enabled` in `ondemand.d`. See [what to enable](#what-to-enable). |
| `OOD_ALLOWLIST_PATH` | No | unset | Open OnDemand's own file allowlist. It is read from the PUN environment, from the Dashboard's env file (`/etc/ood/config/apps/dashboard/env`), and from `allowlist_path` in `/etc/ood/config/ondemand.d`, in that order. The Dashboard in Open OnDemand 4.2 and earlier does not read `allowlist_path` from `ondemand.d`, so on those releases set the allowlist in the Dashboard's env file, which confines both. When set, file access through this API is confined to the same colon-separated paths as the Dashboard file browser. Unset, it is confined to the home and temp directories. |

## Audit log

Every operation writes one line to the PUN's log,
`/var/log/ondemand-nginx/<user>/error.log`, which is owned by root and rotated
by Open OnDemand's own logrotate rule. Each line begins `ood_api_audit ts=`,
so a log shipper can select on that:

```
ood_api_audit ts=2026-11-21T15:25:15.624Z op=list_files user=alice source=rest status=ok duration=0.0097 path=/home/alice token_id=3f6d...
```

| Field | Meaning |
|---|---|
| `ts` | UTC time of the record |
| `op` | The tool name, or `authenticate`, `capabilities`, `site_config`, `file_access`, `mcp_initialize`, `mcp_clients_limit`, `unhandled_error` |
| `user` | The user the PUN runs as |
| `source` | `rest` or `mcp` |
| `status` | `ok`; `error` (the operation failed or was refused by the path rules, with the reason in `error`); `disabled` (the tool is switched off at this site); `denied` (no valid application token); `expired` (an expired application token) |
| `duration` | Seconds, for operations that ran |
| `path`, `cluster`, `job_id` | What the operation was about |
| `script_sha256`, `script_bytes` | On job submission, the digest and size of the script |
| `token_id` | The application token that made the request, when tokens are on |
| `client`, `client_version` | On `mcp_initialize`, the name and version the MCP client gave for itself, cut at 256 characters |
| `protocol_version` | On `mcp_initialize`, the MCP protocol version, for clients of the 2026-07-28 protocol |

Values are quoted and control characters escaped, so a file name cannot
forge a line. There is no request id or client address; match against
Apache's access log by time and user.

`op=mcp_initialize` records which MCP client connected. A client of an older
protocol announces itself with an `initialize` request, and each one is
recorded. A client of the 2026-07-28 protocol sends no `initialize`, and
names itself on every request instead, so it is recorded the first time a
process sees that name and version from that application token: once per
connection over `bin/mcp-stdio`, and once per PUN process for `/mcp`, which
serves every client of the PUN until Passenger recycles it. A process
remembers up to 64 clients; the first one past that is recorded as
`op=mcp_clients_limit`, and later new clients in that process are not
recorded. A name or version that is missing or not a string is not recorded,
and the request is served as usual. The client identity is whatever the
client says it is.

## Troubleshooting

### Health check returns 502 or connection refused

1. Verify the app is installed: `ls /var/www/ood/apps/sys/ood-api/`
2. Check that `bundle install` completed successfully
3. [Restart the affected user's PUN](#restarting-puns)
4. Check PUN logs: `~/ondemand/data/sys/ood-api/` (if they exist) or `/var/log/ondemand-nginx/<user>/`

### 401 Unauthorized with a JWT

1. Verify `OIDCOAuthVerifyJwksUri` is set correctly in `ood_portal.yml`
2. Confirm the token hasn't expired: `echo '<token>' | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool` and compare `exp` with `date +%s`
3. Check that the claim in `OIDCOAuthRemoteUserClaim` matches your IdP's token format
4. Check the Apache error log for the portal's virtual host, for example `sudo tail /var/log/httpd/<servername>_error.log`

### 401 Unauthorized with an application token

The request needs both what Apache accepts (a JWT or a session cookie) and the
`X-OOD-API-Token` header. A missing header, an unknown token and an expired
one all get 401; an expired token also leaves
`op=authenticate status=expired token_id=...` in the PUN log.


1. Verify `~/.config/ondemand/tokens.json` exists and is valid JSON
2. Check file permissions: should be `600`
3. Ensure the PUN is running (requires an active browser session first)

### 503 `misconfigured`, or 404 "not enabled at this site"

503 means the settings could not be understood and the app has switched
itself off. `/health` lists the reasons under `problems`; fix them and the
app comes back within a couple of seconds. 404 with "not enabled at this
site" means `rest` or `mcp` is switched off in the settings.

### 403 "Cross-site requests are not allowed"

A browser request arrived with an `Origin` that is not the portal's own
hostname. The app compares it with the `Host` header and with the last value
of `X-Forwarded-Host`, as the Dashboard does. If a front end on another
hostname is meant to call the API, or a proxy in front of Open OnDemand
rewrites the hostname so that the public name reaches the app as neither of
those, list the public origin in `OOD_API_ALLOWED_ORIGINS`.

### PUN not spawning for API requests

With JWT auth the PUN should spawn automatically. If it doesn't:
1. Verify Apache is setting `REMOTE_USER` by checking the Apache error log for OIDC messages
2. Check that `pun_proxy.lua` is configured to allow the API path

If Apache is gating with a session cookie, the user must log in via browser first to spawn the PUN.

## Upgrading

```bash
cd /var/www/ood/apps/sys/ood-api
sudo git fetch --tags
sudo git checkout <release>
sudo bundle install
sudo chown -R root:root .
```

Then [restart the PUNs](#restarting-puns); a running PUN keeps the old code
until it does. Read the [changelog](../CHANGELOG.md) first. Four things to know
when coming from 0.4:

- Job submission and file writes are now off until you enable them under
  [What to enable](#what-to-enable).
- Bearer access now needs `Require claim aud:` (or `azp:`) in place of
  `Require valid-user`; see [step 2](#2-configure-authentication). With
  `valid-user`, a token your IdP issued to any client is accepted.
- Existing application tokens now expire. Each is given the site maximum,
  365 days unless you set `token_max_days`, counted from its first use after
  the upgrade.
- Application tokens are converted to a hashed form the first time one is
  used. After that, going back to 0.4 leaves every token listed but unusable,
  and users have to create new ones.

## Removing the app

Do it in this order. Deleting the settings file while PUNs are still running
makes them fall back to the defaults, which would lift any restriction the
file held, including the application-token requirement.

1. Switch the app off in `/etc/ood/config/apps/ood-api/config.yml`. Running
   PUNs stop serving within a couple of seconds:

   ```yaml
   rest: false
   mcp: false
   ```

2. Remove the app and its plugin:

   ```bash
   sudo rm -rf /var/www/ood/apps/sys/ood-api
   sudo rm -f /var/lib/ondemand-nginx/config/apps/sys/ood-api.conf
   sudo rm -f /etc/ood/config/plugins/ood-api          # if the plugin was installed
   ```

3. [Restart the PUNs](#restarting-puns). A PUN that was already running keeps
   the app in memory until it does.

4. Only then remove the settings:

   ```bash
   sudo rm -rf /etc/ood/config/apps/ood-api
   ```

If you added the `auth` override during
[step 2](#2-configure-authentication), remove that
block from `ood_portal.yml`, re-run `update_ood_portal`, and restart `httpd` —
this reverts the change for the **whole portal**, so check no other app came to
depend on bearer auth. If you set up OAuth discovery from
[MCP authentication](mcp-auth.md), remove its `custom_vhost_directives` lines
and `/etc/ood/config/mcp` as well, or the portal keeps advertising an MCP
endpoint that is gone. User token files at `~/.config/ondemand/tokens.json` are
left in place; they are inert once the app is gone.

[portal-yml]: https://osc.github.io/ood-documentation/latest/reference/files/ood-portal-yml.html
