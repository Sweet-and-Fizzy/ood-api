# MCP Authentication

This guide configures your OOD site so MCP clients (Claude Code, Claude
Desktop, Cursor, etc.) can authenticate and use the API programmatically.

Two methods are available. Both build on the same core setup — Method 1
is a subset of Method 2, so you can start simple and add OAuth
discovery later.

| | Method 1: Static Token | Method 2: OAuth Discovery |
|---|---|---|
| **Server config** | Core setup only | Core setup + discovery docs |
| **User experience** | Obtain JWT, pass as header | Connect and log in via browser |
| **Token management** | Manual (tokens expire) | Automatic (client handles it) |
| **IdP requirements** | JWKS endpoint | JWKS + Dynamic Client Registration (or pre-registered client) |
| **Best for** | Scripts, CI/CD, quick setup | Interactive use, best UX |

## Prerequisites

- Open OnDemand 3.x or 4.x with ood-api installed
- HTTPS (required in production)
- An OIDC identity provider with a JWKS endpoint (CILogon, Keycloak,
  Dex, institutional IdPs)

## Core setup

Both methods require switching Apache from session-only auth to
session-plus-bearer auth. This is a one-line change in
`/etc/ood/config/ood_portal.yml`.

### Why this is needed

OOD's default `AuthType openid-connect` only accepts browser session
cookies. MCP clients don't use browsers — they send
`Authorization: Bearer <token>` headers. The `auth-openidc` AuthType
(same Apache module) handles both session cookies and bearer tokens.

### Why this is safe

`AuthType auth-openidc` is a superset of `openid-connect` in the same
module (`mod_auth_openidc`). Browser login works exactly as before.
Bearer tokens are validated against the same IdP signing keys (JWKS) —
no weaker authentication path is introduced. The PUN still provides
per-user isolation.

### Configuration

Add to `/etc/ood/config/ood_portal.yml`:

```yaml
auth:
  - "AuthType auth-openidc"
  - "Require valid-user"
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://your-idp.example.edu/certs"
  OIDCOAuthRemoteUserClaim: "sub"
```

The `auth` override applies to all OOD protected locations (`/pun`,
`/nginx`, `/oidc`). This is how OOD's portal generator works — there
is no per-app auth configuration.

Replace the JWKS URI and claim with your identity provider's values:

| Identity Provider | JWKS URI | Claim |
|-------------------|----------|-------|
| CILogon | `https://cilogon.org/oauth2/certs` | `sub` |
| Keycloak | `https://keycloak.example.edu/realms/REALM/protocol/openid-connect/certs` | `preferred_username` or `email` |
| Dex (OOD built-in) | `https://your-ood-host/dex/keys` | `email` |

Regenerate the Apache config and restart:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

### Verify

Test that bearer tokens are accepted:

```bash
# Replace <jwt> with a valid token from your IdP
curl -H "Authorization: Bearer <jwt>" \
  https://ondemand.example.edu/pun/sys/ood-api/health
```

Expected: `{"status":"ok"}`

If you get 401, check the [Troubleshooting](#troubleshooting) section.

## Method 1: Static bearer token

With the core setup complete, users can authenticate by passing a JWT
as a bearer token. No additional server configuration is needed.

### How users get a token

The site provides users with a way to obtain a JWT from the IdP.
Common approaches:

- A helper script that performs the OAuth flow and prints a token
- Direct token request via the IdP's token endpoint (if the IdP
  supports the `client_credentials` or `password` grant)
- An existing institutional token service

### Client configuration

**Claude Code CLI:**

```bash
claude mcp add ood-hpc --transport http \
  --header "Authorization: Bearer <jwt>" \
  https://ondemand.example.edu/pun/sys/ood-api/mcp
```

**Claude Code with headersHelper (auto-refresh):**

Create a helper script that prints the Authorization header (e.g.,
`/usr/local/bin/get-ood-token.sh`). Then in `.mcp.json` or Claude
Code's MCP settings:

```json
{
  "mcpServers": {
    "ood-hpc": {
      "type": "http",
      "url": "https://ondemand.example.edu/pun/sys/ood-api/mcp",
      "headersHelper": "/usr/local/bin/get-ood-token.sh"
    }
  }
}
```

The helper runs at connect time and should output:
```
Authorization: Bearer <jwt>
```

**Claude Desktop (via mcp-remote):**

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "ood-hpc": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "https://ondemand.example.edu/pun/sys/ood-api/mcp",
        "--header",
        "Authorization: Bearer ${OOD_TOKEN}"
      ],
      "env": {
        "OOD_TOKEN": "<jwt>"
      }
    }
  }
}
```

## Method 2: OAuth discovery (automatic)

Method 2 adds OAuth discovery so MCP clients can authenticate
automatically — the user is prompted to log in via browser and the
client handles the rest.

This requires two additional pieces on top of the core setup:
1. Discovery documents that tell clients where to authenticate
2. Apache directives that return 401 (instead of a redirect) for
   non-browser requests, triggering the client's OAuth flow

### Step 1: Add Apache directives

Add these to your `oidc_settings` and `custom_vhost_directives` in
`/etc/ood/config/ood_portal.yml` (in addition to the core setup):

```yaml
oidc_settings:
  # ... existing settings from core setup ...
  OIDCUnAuthAction: '401 "%{HTTP_ACCEPT} !~ m#text/html#"'
custom_vhost_directives:
  - 'Alias "/.well-known/oauth-protected-resource" "/etc/ood/config/mcp/oauth-protected-resource.json"'
  - '<Location "/.well-known/oauth-protected-resource">'
  - '  Require all granted'
  - '  Header always set Content-Type "application/json"'
  - '  Header always set Access-Control-Allow-Origin "*"'
  - '</Location>'
  - 'Alias "/.well-known/oauth-authorization-server" "/etc/ood/config/mcp/oauth-authorization-server.json"'
  - '<Location "/.well-known/oauth-authorization-server">'
  - '  Require all granted'
  - '  Header always set Content-Type "application/json"'
  - '  Header always set Access-Control-Allow-Origin "*"'
  - '</Location>'
  - 'Header always set WWW-Authenticate "Bearer" "expr=%{REQUEST_STATUS} == 401"'
```

`OIDCUnAuthAction` returns 401 for non-browser requests (MCP clients
send `Accept: application/json`, not `text/html`) instead of
redirecting to the IdP login page. Browser users still get the normal
redirect. The `WWW-Authenticate: Bearer` header on 401 responses
signals to MCP clients that OAuth is available.

If you already have `custom_vhost_directives` in your config, append
these lines to the existing list.

### Step 2: Create discovery documents

Create the directory:

```bash
sudo mkdir -p /etc/ood/config/mcp
```

**Protected resource metadata** (`/etc/ood/config/mcp/oauth-protected-resource.json`):

This is the primary discovery document (RFC 9728). MCP clients fetch
it first to learn where to authenticate.

```json
{
  "resource": "https://ondemand.example.edu",
  "authorization_servers": ["https://your-idp.example.edu"],
  "bearer_methods_supported": ["header"],
  "resource_name": "Open OnDemand"
}
```

Set `resource` to your OOD host URL. Set `authorization_servers` to
your IdP's issuer URL.

**Authorization server metadata** (`/etc/ood/config/mcp/oauth-authorization-server.json`):

This tells clients the IdP's OAuth endpoints. If your IdP already
publishes its own at `https://your-idp/.well-known/oauth-authorization-server`,
you can skip this file — clients will fetch it from the IdP directly.

**CILogon example:**

```json
{
  "issuer": "https://cilogon.org",
  "authorization_endpoint": "https://cilogon.org/authorize",
  "token_endpoint": "https://cilogon.org/oauth2/token",
  "registration_endpoint": "https://cilogon.org/oauth2/register",
  "jwks_uri": "https://cilogon.org/oauth2/certs",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"]
}
```

**Keycloak example:**

```json
{
  "issuer": "https://keycloak.example.edu/realms/YOUR_REALM",
  "authorization_endpoint": "https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/auth",
  "token_endpoint": "https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/token",
  "jwks_uri": "https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/certs",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]
}
```

**Dex (OOD built-in) example:**

```json
{
  "issuer": "https://your-ood-host/dex",
  "authorization_endpoint": "https://your-ood-host/dex/auth",
  "token_endpoint": "https://your-ood-host/dex/token",
  "jwks_uri": "https://your-ood-host/dex/keys",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code"],
  "code_challenge_methods_supported": ["S256", "plain"],
  "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]
}
```

Note: The `issuer` field should be your IdP's issuer URL, not your OOD
host URL. MCP clients use this to validate tokens.

### Step 3: Regenerate and restart

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

### Step 4: Verify

Test the discovery endpoints (no auth required):

```bash
curl -s https://ondemand.example.edu/.well-known/oauth-protected-resource | python3 -m json.tool
curl -s https://ondemand.example.edu/.well-known/oauth-authorization-server | python3 -m json.tool
```

Test the 401 response for non-browser requests:

```bash
curl -v -X POST https://ondemand.example.edu/pun/sys/ood-api/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{}' 2>&1 | grep -i "www-authenticate\|HTTP/"
```

Expected: `HTTP/1.1 401` with `WWW-Authenticate: Bearer`.

### Client configuration

**Claude Code CLI:**

```bash
claude mcp add ood-hpc --transport http \
  https://ondemand.example.edu/pun/sys/ood-api/mcp
```

That's it. Claude Code discovers auth automatically and opens a
browser for login.

If your IdP does not support Dynamic Client Registration, provide a
pre-registered client ID:

```bash
claude mcp add ood-hpc --transport http \
  --client-id "your-client-id" \
  https://ondemand.example.edu/pun/sys/ood-api/mcp
```

**Claude Desktop (via mcp-remote):**

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

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

If your IdP does not support Dynamic Client Registration:

```json
{
  "mcpServers": {
    "ood-hpc": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "https://ondemand.example.edu/pun/sys/ood-api/mcp",
        "--static-oauth-client-info",
        "{\"client_id\": \"your-client-id\", \"client_secret\": \"your-secret\"}"
      ]
    }
  }
}
```

### Dynamic Client Registration

For the smoothest experience, the IdP should support Dynamic Client
Registration (RFC 7591). This lets MCP clients register themselves
automatically.

| Identity Provider | DCR Support |
|-------------------|-------------|
| CILogon | Supported natively |
| Keycloak | Can be configured per-realm |
| Dex | Not supported — pre-register a client |

If DCR is not available, pre-register an OAuth client in your IdP with:
- Redirect URI: `http://localhost:PORT/callback` (for desktop clients)
- Grant type: `authorization_code`
- PKCE: required (`S256`)

Give users the client ID to configure in their MCP client settings.

## Application-level tokens

Application-level tokens (the Dashboard plugin at `/settings/api_tokens`)
are validated inside the app, below Apache. MCP clients cannot use them
because Apache requires authentication before the request reaches the
app, and MCP clients don't share browser cookies.

Application-level tokens remain useful for REST API access from scripts
that can be paired with a session cookie, or in development when
running `bin/dev` (which bypasses Apache).

## Troubleshooting

### Bearer token returns 401

**Check `AuthType`:** Verify the Apache config uses `auth-openidc`:

```bash
grep AuthType /etc/httpd/conf.d/ood-portal.conf
```

If it shows `openid-connect`, the `auth` override in `ood_portal.yml`
is missing or the config wasn't regenerated.

**Check the token:** Decode the JWT to inspect claims:

```bash
echo '<token>' | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Verify the `iss` (issuer) and `exp` (expiration) fields.

**Check the JWKS URI:** Confirm Apache can reach it:

```bash
curl -s https://your-idp/certs | python3 -m json.tool
```

### Discovery document returns 404

Check that the `Alias` directives are in your Apache config:

```bash
grep well-known /etc/httpd/conf.d/ood-portal.conf
```

If not present, verify `custom_vhost_directives` in `ood_portal.yml`
and re-run `update_ood_portal`.

### 401 response has no WWW-Authenticate header

The `Header always set WWW-Authenticate` directive may be missing from
`custom_vhost_directives`, or Apache hasn't been restarted:

```bash
grep WWW-Authenticate /etc/httpd/conf.d/ood-portal.conf
```

### MCP client doesn't attempt OAuth

The client may not support the MCP authorization spec. Use Method 1
(static bearer token) as a fallback.

### Browser login broken after changes

Verify the `oidc_remote_user_claim` is still set in `ood_portal.yml`.
The `auth` override only changes `AuthType` — OIDC session config is
separate.

## See also

- **[API reference](api.md)** — File read/write limits, historic jobs
  behavior, and error semantics
- **[README](../README.md)** — Installation, configuration, and
  application-level tokens for REST API access
