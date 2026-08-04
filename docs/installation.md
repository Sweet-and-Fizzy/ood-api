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

# Pin to a release (recommended)
# sudo git checkout v0.4.1

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
  - "Require valid-user"
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://your-idp.example.edu/certs"
  OIDCOAuthRemoteUserClaim: "preferred_username"
```

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

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
| CILogon via ACCESS | `sub` | the ACCESS ID (`someone@access-ci.org`) |
| CILogon (no named config) | — | `sub` is an opaque URL, unusable for mapping |

#### Optional: application tokens

Skip this unless you want per-client credentials — one token per laptop or CI
runner, each revocable on its own from **Settings > API Tokens**, where a JWT is
all-or-nothing.

Set `OOD_API_APP_TOKENS=true` on the PUN and install the Dashboard plugin
(OOD 4.0+):

```bash
ln -s /var/www/ood/apps/sys/ood-api/dashboard-plugin /etc/ood/config/plugins/ood-api
```

Every request to `/api/v1/*` and `/mcp` must then carry `X-OOD-API-Token:
<token>` **in addition to** whatever Apache accepts — the token is a second
factor, never a credential on its own. Its own header is what lets it coexist
with the JWT in `Authorization`. Restart the PUN; token management appears at
`/settings/api_tokens`.

If that page 404s, check that every file under `dashboard-plugin/` is root-owned
— OOD skips plugins that aren't, silently. The plugin logs `OOD API plugin
loaded` through Rails, so look in the Dashboard's own log
(`~/ondemand/data/sys/dashboard/log/production.log`) rather than the PUN log.

**A caveat if your IdP does not issue JWT access tokens** (Google OIDC, and
CILogon unless it has configured a token handler for your client): Apache then
only accepts a browser session cookie, so a script has to carry a cookie copied
from DevTools that expires with the OIDC session — 8 hours by default. Fine
occasionally, poor for anything unattended. See
[the REST API guide](api.md#application-tokens) for the full flow, and
[If your IdP issues opaque access tokens](mcp-auth.md#if-your-idp-issues-opaque-access-tokens)
for the introspection alternative.

Tokens can also be created manually:

```bash
mkdir -p ~/.config/ondemand
TOKEN=$(python -c "import secrets; print(secrets.token_hex(32))")
cat > ~/.config/ondemand/tokens.json << EOF
[{"id": "$(uuidgen)", "name": "My Token", "token": "$TOKEN", "created_at": "$(date -Iseconds)"}]
EOF
chmod 600 ~/.config/ondemand/tokens.json
echo "Your token: $TOKEN"
```

### 3. Register the app with NGINX

OOD normally stages an app the first time someone opens it in the browser.
ood-api is `hidden: true`, so there is no tile to click and an API client gets
the "App has not been initialized" page as a 404 instead. Stage it once:

```bash
sudo /opt/ood/nginx_stage/sbin/nginx_stage app \
  --user=$USER --sub-uri=/pun --sub-request=/sys/ood-api
```

One command per site, not per user — the generated config is shared, so every
user gets a working API from their first request.

### 4. MCP Endpoint

The MCP endpoint is at `/mcp`. Configure your MCP client to connect via HTTP:

**Claude Code CLI:**

```bash
claude mcp add ood-hpc --transport http https://ondemand.example.edu/pun/sys/ood-api/mcp
```

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
reported: MCP tools return a protocol error, REST returns an HTTP status. See
[Configuration](#configuration) for the settings and
[SECURITY.md](../SECURITY.md) for what they do.

### 5. Verify

```bash
curl -H "Authorization: Bearer <your-jwt>" \
  https://ondemand.example.edu/pun/sys/ood-api/health
```

A successful response confirms the API is running. A **404 returning an HTML
page** titled "App has not been initialized" means step 3 has not been done.

## Configuration

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
| `OOD_API_APP_TOKENS` | No | unset | Set to `true` to require a per-client `X-OOD-API-Token` header in addition to Apache's auth. See [application tokens](#optional-application-tokens). |
| `OOD_API_MAX_FILE_READ` | No | `10485760` (10 MB) | Maximum file read size in bytes (REST and MCP `read_file`) |
| `OOD_API_MAX_FILE_WRITE` | No | `52428800` (50 MB) | Maximum request body size in bytes for **every** `/api/v1/*` request, not only file writes — job submission and the MCP envelope are bounded by it too. Lowering it to restrict uploads also caps how large a job script may be. |
| `OOD_API_ENV_ALLOWLIST` | No | See [docs/api.md](api.md#environment-variable-allowlist) | Comma-separated allowlist for env vars endpoint. Entries ending in `*` are prefix matches. |
| `OOD_API_CONTEXT_PATH` | No | `/etc/ood/config/agents.d` | Path to directory containing site-specific agent context files (*.md) |
| `OOD_API_MAX_CONTEXT_BYTES` | No | `262144` (256 KB) | Per-file cap on agent context fragments. A larger file is replaced with a note rather than served. |
| `OOD_API_MAX_CONTEXT_TOTAL_BYTES` | No | `1048576` (1 MB) | Cap across all context fragments together. The per-file cap alone bounds nothing when there are many files. |
| `OOD_API_ALLOW_NATIVE` | No | unset | Set to `true` to accept `options.native` on job submission. It is raw scheduler argv and can override the paths this API validates, so it is off by default — see [the note in the API guide](api.md#submit-job). |

## Troubleshooting

### Health check returns 502 or connection refused

1. Verify the app is installed: `ls /var/www/ood/apps/sys/ood-api/`
2. Check that `bundle install` completed successfully
3. Restart the affected user's PUN: `sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean --user=<user>` (without `--user` this cleans every user's PUN)
4. Check PUN logs: `~/ondemand/data/sys/ood-api/` (if they exist) or `/var/log/ondemand-nginx/<user>/`

### 401 Unauthorized with a JWT

1. Verify `OIDCOAuthVerifyJwksUri` is set correctly in `ood_portal.yml`
2. Confirm the token hasn't expired: `echo '<token>' | cut -d. -f2 | base64 -d | python -m json.tool`
3. Check that the claim in `OIDCOAuthRemoteUserClaim` matches your IdP's token format
4. Check Apache error log: `sudo tail /var/log/httpd/error_log`

### 401 Unauthorized with an application token

1. Verify `~/.config/ondemand/tokens.json` exists and is valid JSON
2. Check file permissions: should be `600`
3. Ensure the PUN is running (requires an active browser session first)

### PUN not spawning for API requests

With JWT auth the PUN should spawn automatically. If it doesn't:
1. Verify Apache is setting `REMOTE_USER` by checking the Apache error log for OIDC messages
2. Check that `pun_proxy.lua` is configured to allow the API path

If Apache is gating with a session cookie, the user must log in via browser first to spawn the PUN.

## Removing the app

```bash
sudo rm -rf /var/www/ood/apps/sys/ood-api
sudo rm -f /var/lib/ondemand-nginx/config/apps/sys/ood-api.conf
sudo rm -f /etc/ood/config/plugins/ood-api          # if the plugin was installed
```

If you added the `auth` override during
[step 2](#2-configure-authentication), remove that
block from `ood_portal.yml`, re-run `update_ood_portal`, and restart `httpd` —
this reverts the change for the **whole portal**, so check no other app came to
depend on bearer auth. User token files at `~/.config/ondemand/tokens.json` are
left in place; they are inert once the app is gone.

[portal-yml]: https://osc.github.io/ood-documentation/latest/reference/files/ood-portal-yml.html
