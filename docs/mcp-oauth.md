# MCP OAuth Configuration

This guide enables MCP clients (Claude Desktop, Claude Code, Cursor, etc.)
to authenticate with your OOD API automatically using OAuth, instead of
requiring users to manually copy bearer tokens.

## How it works

When an MCP client connects to your OOD API's `/mcp` endpoint without
authentication, it receives a 401 response. The client then looks for an
OAuth discovery document at `/.well-known/oauth-authorization-server` on
your OOD host. This document tells the client where to send users to log
in (your site's identity provider).

The flow is:

1. MCP client hits `/pun/sys/ood-api/mcp` → gets 401 with `WWW-Authenticate: Bearer`
2. Client fetches `/.well-known/oauth-authorization-server` → gets IdP URLs
3. Client opens a browser for the user to log in via the IdP
4. IdP issues a JWT token → client sends it with subsequent requests
5. Apache validates the token via JWKS → request proceeds to ood-api

This uses the same OIDC identity provider your OOD portal already uses —
no additional auth infrastructure needed.

## Prerequisites

- Open OnDemand with ood-api installed (HTTPS required in production)
- An OIDC identity provider with a JWKS endpoint (CILogon, Keycloak, etc.)
- The IdP's OAuth endpoint URLs (check your IdP's
  `/.well-known/openid-configuration` document)

## Step 1: Enable bearer token validation

Add to your `/etc/ood/config/ood_portal.yml`:

```yaml
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://your-idp.example.edu/oauth2/certs"
  OIDCOAuthRemoteUserClaim: "sub"
  OIDCUnAuthAction: '401 "%{HTTP_ACCEPT} !~ m#text/html#"'
```

Replace the JWKS URI with your identity provider's certificate endpoint:

| Identity Provider | JWKS URI |
|-------------------|----------|
| CILogon | `https://cilogon.org/oauth2/certs` |
| Keycloak | `https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/certs` |
| Dex (OOD built-in) | `https://your-ood-host/dex/keys` |

The `OIDCOAuthRemoteUserClaim` controls which JWT claim becomes the
username. Common values:

| Identity Provider | Claim |
|-------------------|-------|
| CILogon | `sub` |
| Keycloak | `preferred_username` or `email` |
| Dex | `email` |

These settings do three things:

- **`OIDCOAuthVerifyJwksUri`** enables bearer token validation — tokens in
  `Authorization: Bearer` headers are validated against the IdP's signing keys.
- **`OIDCOAuthRemoteUserClaim`** maps the JWT claim to the system username.
- **`OIDCUnAuthAction`** tells mod_auth_openidc to return 401 (instead of
  redirecting to the IdP login page) for non-browser requests. MCP clients
  send `Accept: application/json`, not `text/html`, so they get a 401 and
  can initiate the OAuth flow. Browser users still get the normal redirect.

Regenerate the Apache config and restart:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

## Step 2: Create the OAuth discovery document

Create the directory:

```bash
sudo mkdir -p /etc/ood/config/mcp
```

Create `/etc/ood/config/mcp/oauth-authorization-server.json` with your
IdP's endpoints. You can find these in your IdP's OIDC discovery document
at `https://your-idp.example.edu/.well-known/openid-configuration`.

**CILogon example:**

```json
{
  "issuer": "https://ondemand.example.edu",
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
  "issuer": "https://ondemand.example.edu",
  "authorization_endpoint": "https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/auth",
  "token_endpoint": "https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/token",
  "jwks_uri": "https://keycloak.example.edu/realms/YOUR_REALM/protocol/openid-connect/certs",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["client_secret_basic", "client_secret_post"]
}
```

Notes:

- The `issuer` field should be **your OOD host URL**, not your IdP's URL.
  MCP clients treat your OOD host as the authorization server.
- Include `registration_endpoint` only if your IdP supports OAuth 2.0
  Dynamic Client Registration (RFC 7591). CILogon does; Keycloak can be
  configured to. If not included, users will need to configure a client ID
  manually — see [Client Registration](#client-registration) below.

## Step 3: Serve the discovery document via Apache

Add to your `/etc/ood/config/ood_portal.yml`:

```yaml
custom_vhost_directives:
  - 'Alias "/.well-known/oauth-authorization-server" "/etc/ood/config/mcp/oauth-authorization-server.json"'
  - '<Location "/.well-known/oauth-authorization-server">'
  - '  Require all granted'
  - '  Header always set Content-Type "application/json"'
  - '  Header always set Access-Control-Allow-Origin "*"'
  - '</Location>'
  - 'Header always set WWW-Authenticate "Bearer" "expr=%{REQUEST_STATUS} == 401"'
```

The last line adds a `WWW-Authenticate: Bearer` header to all 401
responses. This tells MCP clients that the server accepts OAuth bearer
tokens, which is required by the OAuth 2.1 spec (RFC 6750). The `expr`
condition ensures it only applies to 401 responses, not other status
codes.

If you already have `custom_vhost_directives` in your config, append
these lines to the existing list.

Regenerate the Apache config and restart:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

## Step 4: Verify

Test the discovery endpoint (no auth required):

```bash
curl -s https://ondemand.example.edu/.well-known/oauth-authorization-server | python3 -m json.tool
```

Expected: your JSON discovery document with IdP URLs.

Test the 401 response includes `WWW-Authenticate`:

```bash
curl -v -X POST https://ondemand.example.edu/pun/sys/ood-api/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{}' 2>&1 | grep -i www-authenticate
```

Expected: `WWW-Authenticate: Bearer` (exact format may vary by
mod_auth_openidc version).

## Client registration

If your IdP supports **dynamic client registration** (RFC 7591), MCP
clients can register automatically — no manual setup needed. Include
the `registration_endpoint` in your discovery document and you're done.

If your IdP does **not** support dynamic registration, users need a
client ID to authenticate. Options:

1. **Pre-register an OAuth client** in your IdP for MCP access. Set the
   redirect URI to match what MCP clients expect (typically
   `http://localhost:PORT/callback` for desktop clients). Give users the
   client ID to configure in their MCP client settings.

2. **Use application-level tokens** as a fallback. Users create a token
   in the OOD Dashboard plugin and configure their MCP client with it
   directly. This bypasses OAuth entirely but requires an active browser
   session to spawn the PUN.

## MCP client configuration

### Claude Code CLI

```bash
claude mcp add ood-hpc --transport http https://ondemand.example.edu/pun/sys/ood-api/mcp
```

If OAuth is configured, Claude Code will handle authentication
automatically when it first connects.

### Claude Desktop

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

Note: Claude Desktop's "Connector" feature (in the UI) requires a
publicly accessible HTTPS server and routes through Anthropic's
infrastructure. The config file approach above connects directly from
your machine and is the recommended method.

## Troubleshooting

### Discovery document returns 404

Check that the `Alias` directive is in your generated Apache config:

```bash
grep -i well-known /etc/httpd/conf.d/ood-portal.conf
```

If not present, verify `custom_vhost_directives` in your `ood_portal.yml`
and re-run `update_ood_portal`.

### 401 response has no WWW-Authenticate header

`OIDCOAuthVerifyJwksUri` is not set or Apache hasn't been restarted:

```bash
grep OIDCOAuth /etc/httpd/conf.d/ood-portal.conf
```

### Bearer token returns 401

The token may be expired, issued by a different IdP, or the JWKS URI
may be wrong. Decode the token to inspect:

```bash
echo 'YOUR_TOKEN' | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

Verify the `iss` (issuer) claim and `exp` (expiration) fields.

### MCP client doesn't attempt OAuth

The client may not support the MCP authorization spec yet. As a fallback,
users can obtain a token manually from the IdP and configure it in their
MCP client, or use application-level tokens (Option B in the README).

## See also

- **[API reference](api.md)** — File read/write limits (`OOD_API_MAX_FILE_READ`, `OOD_API_MAX_FILE_WRITE`), historic jobs behavior, and error semantics. The same limits apply to MCP `read_file` / `write_file` as to REST.
- **[README](../README.md)** — Audit logging (`ood_api_audit` on stderr), local `/mcp` security notes, and scheduler-dependent features (historic jobs, hold/release, dependencies).
