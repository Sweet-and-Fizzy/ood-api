# MCP Authentication

This guide configures your OOD site so MCP clients (Claude Code, Claude
Desktop, Cursor, etc.) can authenticate and use the API programmatically.

Both methods below produce the same thing: a **JWT in an `Authorization: Bearer`
header**, which is what ood-api authenticates with. They differ only in how the
client obtains that JWT. This is separate from
[application tokens](installation.md#optional-application-tokens), which some
sites require *in addition* in an `X-OOD-API-Token` header.

Both build on the same core setup — Method 1 is a subset of Method 2, so you can
start simple and add OAuth discovery later.

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

Both methods require Apache to accept bearer tokens rather than session
cookies alone — the `auth` override in `/etc/ood/config/ood_portal.yml`. That is
[installation step 2](installation.md#2-configure-authentication); if you
followed the install guide you have already done it, and the rest of this
section is background on *why*.

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

### A revoked token keeps working until it expires

Worth knowing before you deploy this, because it applies to every method
below. JWT validation at Apache is stateless: `mod_auth_openidc` verifies
the signature against the JWKS and checks expiry, but never asks the IdP
whether the token is still good. Revoking a token at the IdP therefore has
no effect until it expires on its own.

If prompt revocation matters at your site, the options are short
access-token lifetimes paired with refresh, or introspecting on every
request — which adds a network dependency to every API call. Neither is
implemented in ood-api today.

### Configuration

This is the same Apache change as
[installation step 2](installation.md#2-configure-authentication) — **if you
have already done it, skip to [Method 1](#method-1-static-bearer-token).** Do
not re-copy the config from here; the claim value in particular is
site-specific and getting it wrong is the most common failure.

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
  "device_authorization_endpoint": "https://cilogon.org/oauth2/device_authorization",
  "revocation_endpoint": "https://cilogon.org/oauth2/revoke",
  "introspection_endpoint": "https://cilogon.org/oauth2/introspect",
  "jwks_uri": "https://cilogon.org/oauth2/certs",
  "response_types_supported": ["code"],
  "grant_types_supported": [
    "authorization_code",
    "refresh_token",
    "urn:ietf:params:oauth:grant-type:device_code"
  ],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"]
}
```

> **Note:** this is a minimal example listing only what MCP clients need.
> CILogon's live metadata at
> `https://cilogon.org/.well-known/openid-configuration` advertises more,
> including `client_credentials` and RFC 8693 token-exchange. It also
> lists its registration endpoint as `/oauth2/oidc-cm`, which is the
> RFC 7592 management endpoint and cannot create a client — client
> registration is the manual web form at `/oauth2/register`. See Dynamic
> Client Registration below. Prefer fetching the live document over
> copying this file when your IdP publishes its own.

> **Note on other CILogon grants.** Beyond the authorization code flow
> used here, CILogon's published metadata also advertises
> `refresh_token`, `device_code`, `client_credentials`, and RFC 8693
> token-exchange, plus revocation and introspection endpoints. These are
> **not tested against ood-api** and are not part of either method
> documented here — see [Token lifecycle](#token-lifecycle-untested)
> below before relying on them.

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
| CILogon | **No** — pre-register the client, see below |
| Keycloak | Can be configured per-realm |
| Dex | Not supported — pre-register a client |

DCR is a convenience for the operator, not a prerequisite. Without it,
clients still discover endpoints from the documents above and run the
OAuth flow without users pasting tokens — they just need a client ID you
provisioned in advance.

> **Register the client once, during endpoint setup.** MCP clients cannot
> self-register with CILogon, but this is an operator setup step rather than
> something in your users' path — do it in the same sitting as editing
> `ood_portal.yml` and writing the discovery documents, then publish the
> client ID to users.
>
> **ACCESS sites** register through the ACCESS registry at
> [`registry.access-ci.org`](https://registry.access-ci.org/registry/oa4mp_client/oa4mp_client_co_oidc_clients/add/co:4),
> which is self-service with immediate creation. Choose the **"ACCESS OIDC
> client configuration v1"** named configuration: it returns the ACCESS ID
> (`someone@access-ci.org`, the eduPersonPrincipalName) as the OIDC `sub`
> claim — so ACCESS sites set `OIDCOAuthRemoteUserClaim: "sub"`, unlike the
> `preferred_username` a plain Keycloak site uses.
>
> **Other sites** use CILogon's form at `https://cilogon.org/oauth2/register`,
> which states that requests are manually evaluated with a one-business-day
> turnaround. (The `/oauth2/oidc-cm` endpoint in CILogon's published metadata
> is the RFC 7592 *management* endpoint — it updates an already-approved
> client and cannot create one.)
>
> **Tick the refresh-token option when you create the client** if you want
> refresh tokens available. It is a per-client setting fixed at registration,
> not a scope clients can request later, and changing it afterwards means
> editing or re-creating the client.

If DCR is not available, pre-register an OAuth client in your IdP with:
- Redirect URI: `http://localhost:PORT/callback` (for desktop clients)
- Grant type: `authorization_code`
- PKCE: required (`S256`)

Give users the client ID to configure in their MCP client settings.

## Token lifecycle (untested)

Everything in this section is derived from CILogon's published metadata
and from probing its endpoints. **None of it has been exercised
end-to-end against ood-api.** The two methods above are tested; this is
not. Treat it as a starting point for your own testing, not as
procedure.

CILogon's `.well-known/openid-configuration` advertises five grant
types (`authorization_code`, `refresh_token`, `client_credentials`,
`device_code`, and RFC 8693 token-exchange) plus revocation and
introspection endpoints. Three are potentially relevant here.

**Refresh tokens** would remove most of the manual token replacement
Method 1 requires. The constraint is that refresh must be enabled
per-client at registration — see the note under Dynamic Client
Registration — so it is a decision made when the client is approved,
not a scope requested at authorization time. Untested against ood-api.

**Device code flow** suits a client with no browser, such as an agent
running on a compute node. The node displays a short code the user
approves from another device, avoiding a long-lived token pasted into
the job environment. Untested against ood-api.

## Application tokens

If your site also enables per-client application tokens, an MCP client sends
both headers — `Authorization: Bearer <jwt>` for Apache and `X-OOD-API-Token`
for the app. A client that cannot set a custom header should rely on
Apache-level auth alone. Full details in
[the REST API guide](api.md#application-tokens).

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

- **[User Guide](user-guide.md)** — end-user guide to authenticating and using
  the REST API and MCP tools
- **[API reference](api.md)** — File read/write limits, historic jobs
  behavior, and error semantics
- **[Installation](installation.md)** — deploying and configuring ood-api
- **[README](../README.md)** — what the app does and its security posture
