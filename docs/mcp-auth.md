# MCP Authentication

This guide configures your OOD site so MCP clients (Claude Code, Claude
Desktop, Cursor, etc.) can authenticate and use the API programmatically.

Both methods below produce the same thing: a **bearer token in an
`Authorization` header**, which Apache validates before the request reaches
ood-api. They differ only in how the client obtains that token. This is
separate from [application tokens](installation.md#optional-application-tokens),
which some sites require *in addition* in an `X-OOD-API-Token` header.

Both methods assume your IdP issues **JWT access tokens**, which Apache can
validate offline against a JWKS. Not every IdP does — CILogon issues opaque
access tokens by default, and neither method works as written there. See
[If your IdP issues opaque access tokens](#if-your-idp-issues-opaque-access-tokens)
before you start.

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
- An OIDC identity provider that issues **JWT access tokens** and publishes a
  JWKS endpoint (Keycloak, Dex, many institutional IdPs). CILogon issues
  opaque access tokens by default and needs
  [a different approach](#if-your-idp-issues-opaque-access-tokens).

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
module (`mod_auth_openidc`). Browser login works exactly as before, and the
PUN still provides per-user isolation.

It is safe only with the audience requirement from the install guide.
Apache validates a bearer token's signature against the IdP's signing keys
(JWKS) and its expiry, and does not check who the token was issued to. With
`Require valid-user`, a token the same IdP issued to any other service is a
full portal login for its owner. `Require claim aud:<your OOD client id>`
restricts bearer access to tokens issued for Open OnDemand.

### A revoked token keeps working until it expires

Worth knowing before you deploy this, because it applies to every method
below. JWT validation at Apache is stateless: `mod_auth_openidc` verifies
the signature against the JWKS and checks expiry, but never asks the IdP
whether the token is still good. Revoking a token at the IdP therefore has
no effect until it expires on its own.

If prompt revocation matters at your site, the options are short
access-token lifetimes paired with refresh, or introspecting on every
request — `OIDCOAuthTokenIntrospectionInterval -1`, which adds a network
dependency to every API call. Introspection at its default interval does
*not* help: it caches until the token's own expiry, so it gives the same
guarantee as JWKS validation. Neither option is implemented in ood-api today.

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

This requires three additional pieces on top of the core setup:
1. A discovery document that tells clients where to authenticate
2. Apache directives that return 401 (instead of a redirect) for
   non-browser requests, triggering the client's OAuth flow
3. An entry allowing the OAuth client your MCP clients use

### Step 1: Add Apache directives

Add these to your `oidc_settings` and `custom_vhost_directives` in
`/etc/ood/config/ood_portal.yml` (in addition to the core setup). Replace
`https://ondemand.example.edu` with your portal's URL in the last line.

```yaml
oidc_settings:
  # ... existing settings from core setup ...
  OIDCUnAuthAction: '401 "%{HTTP_ACCEPT} !~ m#text/html#"'
custom_vhost_directives:
  - 'AliasMatch "^/\.well-known/oauth-protected-resource(/pun/sys/ood-api/mcp)?$" "/etc/ood/config/mcp/oauth-protected-resource.json"'
  - '<LocationMatch "^/\.well-known/oauth-protected-resource">'
  - '  Require all granted'
  - '  Header always set Content-Type "application/json"'
  - '  Header always set Access-Control-Allow-Origin "*"'
  - '</LocationMatch>'
  - '<Directory "/etc/ood/config/mcp">'
  - '  Require all granted'
  - '</Directory>'
  - 'Header always set WWW-Authenticate "Bearer resource_metadata=\"https://ondemand.example.edu/.well-known/oauth-protected-resource/pun/sys/ood-api/mcp\"" "expr=%{REQUEST_STATUS} == 401"'
```

`OIDCUnAuthAction` returns 401 for non-browser requests (MCP clients
send `Accept: application/json`, not `text/html`) instead of
redirecting to the IdP login page. Browser users still get the normal
redirect.

The `WWW-Authenticate` header on a 401 carries `resource_metadata`, the URL
of the document that tells the client where to authenticate (RFC 9728). The
document is served at that URL and at the bare
`/.well-known/oauth-protected-resource`, which older clients try.

If you already have `custom_vhost_directives` in your config, append
these lines to the existing list.

### Step 2: Create the discovery document

```bash
sudo mkdir -p /etc/ood/config/mcp
```

**Protected resource metadata** (`/etc/ood/config/mcp/oauth-protected-resource.json`):

```json
{
  "resource": "https://ondemand.example.edu/pun/sys/ood-api/mcp",
  "authorization_servers": ["https://your-idp.example.edu"],
  "bearer_methods_supported": ["header"],
  "resource_name": "Open OnDemand"
}
```

Set `resource` to the full URL of the MCP endpoint, exactly as users
configure it in their client. Set `authorization_servers` to your IdP's
issuer URL, exactly as the IdP states it in its own metadata.

If access depends on a scope (the Keycloak audience scope described under
[Which clients may connect](#which-clients-may-connect)), add
`"scopes_supported": ["email", "ood-mcp"]`. Clients request exactly this list,
and use it when self-registering. Include the scope that carries your
`OIDCOAuthRemoteUserClaim` (`email` in the tested setup), or the token arrives
without a username and Apache answers 401 after a login that appeared to
succeed. Leave `openid` out: Keycloak rejects a registration that names it.
Every pre-registered client needs the listed scopes assigned too, or its login
fails with `invalid_scope`.

That is the only document to host. Clients fetch the authorization server's
metadata from the IdP itself. For an issuer with a path, such as Keycloak's
`https://idp.example.edu/realms/hpc`, they try
`https://idp.example.edu/.well-known/oauth-authorization-server/realms/hpc`
first (Keycloak 26.8.2 serves it, 26.0.8 does not) and fall back to
`<issuer>/.well-known/openid-configuration`, which every IdP named in this
guide publishes. Do not host a copy on the OOD server: the `issuer` in
that document has to match the URL it was fetched from, so clients reject a
copy served from another host.

### Which clients may connect

A client that authenticates this way gets a token issued to *its own* OAuth
client ID, not to Open OnDemand's. The audience requirement from
[installation step 2](installation.md#2-configure-authentication) refuses
that token until you allow the client. Add one line per client ID to `auth`
in `ood_portal.yml`:

```yaml
auth:
  - "AuthType auth-openidc"
  - "Require claim aud:YOUR_OOD_CLIENT_ID"
  - "Require claim aud:YOUR_MCP_CLIENT_ID"
```

Apache accepts a request that satisfies any one of the `Require` lines.

On Keycloak write these as `azp:` lines (`Require claim
azp:YOUR_OOD_CLIENT_ID`, `Require claim azp:YOUR_MCP_CLIENT_ID`), or give the
MCP client an audience mapper that adds the OOD client to `aud`. `aud` may be
an array; the line matches if any member equals the value. `azp:` and `aud:`
lines can be mixed.

This is why pre-registering one client for MCP use is the safe arrangement.
With Dynamic Client Registration, any software can register a client at your
IdP and get a new client ID, so there is no fixed list to allow. Accepting
every client is the `Require valid-user` configuration, which lets a token
issued to any service log in to the whole portal. DCR is safe only if your
IdP puts the *resource* in the token's audience, so that you can require
`aud:https://ondemand.example.edu/pun/sys/ood-api/mcp`. Dex and Keycloak
(checked on 26.0.8 and 26.8.2) both ignore the RFC 8707 `resource` parameter.

On Keycloak the same result comes from a client scope. Create a scope (for
example `ood-mcp`) with an Audience mapper whose custom audience is the MCP
URL, add it to the realm's *optional* default client scopes, and list it in
`scopes_supported` in the discovery document (see Step 2) so clients request
it. Self-registered clients then get the audience only on tokens they
requested for Open OnDemand, and their other tokens are refused. Do not make
it a *default* scope: every client created afterwards would carry the
audience on every token. Keep a second line for the portal itself (`Require
claim azp:YOUR_OOD_CLIENT_ID`), since its tokens do not carry the MCP
audience. This was run end to end with the official MCP client SDK (1.32.2),
including self-registration.

This limits which *tokens* are accepted, not which software may register. Any
client that can reach the registration endpoint can ask for the scope; the
user's login and Keycloak's consent screen are what stand in its way.

### Step 3: Regenerate and restart

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

### Step 4: Verify

Test the discovery document (no auth required):

```bash
curl -s https://ondemand.example.edu/.well-known/oauth-protected-resource/pun/sys/ood-api/mcp | python3 -m json.tool
```

Test the 401 response for non-browser requests:

```bash
curl -v -X POST https://ondemand.example.edu/pun/sys/ood-api/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{}' 2>&1 | grep -i "www-authenticate\|HTTP/"
```

Expected: `HTTP/1.1 401` with
`WWW-Authenticate: Bearer resource_metadata="https://ondemand.example.edu/.well-known/oauth-protected-resource/pun/sys/ood-api/mcp"`.

Then check both directions of the audience rule: a token obtained through
your MCP client ID must get a 200 from `/mcp`, and a token issued to any
client you have not listed must get a 401.

This setup was checked on Open OnDemand 4.2.5 with the bundled Dex: the
official MCP client SDK (1.32.2) followed the 401 to the metadata and on to
Dex, and a token from an authorization-code flow with PKCE through a
pre-registered public client was accepted by `/mcp`. It was also run against
Keycloak 26.0.8, with a pre-registered client and with a self-registered one.
It has not been run against CILogon, or driven from an interactive MCP
client.

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

Dynamic Client Registration (RFC 7591) lets MCP clients register
themselves at the IdP automatically. Read
[Which clients may connect](#which-clients-may-connect) before turning it
on: a self-registered client gets a client ID you have not allowed, so its
tokens are refused unless your IdP can put the resource in the audience.
Pre-registering one client is the arrangement this guide has tested.

| Identity Provider | DCR Support |
|-------------------|-------------|
| CILogon | **No** — pre-register the client, see below |
| Keycloak | Yes, but anonymous registration is refused until you add the registering hosts to the realm's "Trusted Hosts" client registration policy (or hand out initial access tokens) |
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

## If your IdP issues opaque access tokens

Both methods above rely on Apache validating a bearer token offline: it fetches
the IdP's signing keys once and checks the token's signature itself. That only
works when the access token is a **JWT** — a signed, self-describing token.

Some IdPs issue **opaque** access tokens instead: a random string that carries
no claims and cannot be validated without asking the IdP about it. Local
validation against a JWKS does not apply, so Apache has to ask the IdP —
configure `OIDCOAuthIntrospectionEndpoint` with a client ID and secret rather
than relying on `OIDCOAuthVerifyJwksUri`.

The three directives go in `oidc_settings`, the same block
[installation step 2](installation.md#2-configure-authentication) already uses.
The portal generator emits each key verbatim as an Apache directive, but only
inside the OIDC block — so `oidc_uri`, `oidc_provider_metadata_url` and
`oidc_client_id` must already be set, which they are at any site doing browser
SSO:

```yaml
oidc_settings:
  OIDCOAuthIntrospectionEndpoint: 'https://cilogon.org/oauth2/introspect'
  OIDCOAuthClientID: 'cilogon:/client_id/YOUR_CLIENT_ID'
  OIDCOAuthClientSecret: 'YOUR_CLIENT_SECRET'
  OIDCOAuthRemoteUserClaim: 'username'
```

Replace `OIDCOAuthVerifyJwksUri` from
[installation step 2](installation.md#2-configure-authentication) with these —
they are alternative validation paths, not additions.

**`OIDCOAuthRemoteUserClaim` is the setting to get right**, and its value
differs from the JWKS path. Under introspection the "claims" are the fields of
the *introspection response*, not of a JWT. CILogon's response contains
`client_id`, `exp`, `iat`, `iss`, `jti`, `nbf`, `scope`, `token_type` and
`username` — note there is **no `sub`**, which is `mod_auth_openidc`'s default
and is also what the install guide tells ACCESS sites to use for JWT
validation. Left at the default, every request fails to map a user. Set it to
a field your response actually contains, and make sure that value is one your
[`user_map_match`](https://osc.github.io/ood-documentation/latest/reference/files/ood-portal-yml.html)
accepts.

**The audience line changes too.** The response has no `aud`, so `Require
claim aud:...` from the install guide refuses every introspected token. The
client is in `client_id` instead. Keep the `aud:` line, which browser
sessions satisfy, and add a `client_id:` line for bearer tokens:

```yaml
auth:
  - "AuthType auth-openidc"
  - "Require claim aud:cilogon:/client_id/YOUR_CLIENT_ID"
  - "Require claim client_id:cilogon:/client_id/YOUR_CLIENT_ID"
```

This follows from the fields listed above and from how the `Require` lines
combine, which was checked with other IdPs. It has not been run against
CILogon. Confirm it the same way as any other setup: a token issued to
another client must get a 401.

The other defaults are usually fine: client authentication is
`client_secret_basic` and the token is sent as the `token` parameter.

**This does not cost a round trip per request.** `mod_auth_openidc` caches an
introspection result until the token's own expiry —
`OIDCOAuthTokenIntrospectionInterval` defaults to `0`, meaning "cache until
`exp`". Setting it to `-1` is what makes it introspect on every request, and a
positive value bounds the cache to that many seconds. The same directive also
bounds the cache for locally validated JWTs, so it is worth knowing whichever
path you take.

The corollary matters more than the cost: at the default, revoking a token at
the IdP does not take effect until it expires — the same limitation
[described above](#a-revoked-token-keeps-working-until-it-expires) for JWKS
validation. **Introspection does not buy prompt revocation unless you set
`-1`**, and that is the setting that costs a round trip.

**Two caveats before you build on this.** Upstream marks the OAuth 2.0
resource-server functionality in `mod_auth_openidc` — the whole `OIDCOAuth*`
family — as deprecated and superseded by
[`mod_oauth2`](https://github.com/OpenIDC/mod_oauth2). In practice that does
not change what you should do today: OOD's portal generator emits only what you
put in `oidc_settings`, and has no way to configure a different module, so
`OIDCOAuth*` is the path available at an OOD site. The directives work in
current releases. Treat the deprecation as a reason to watch upstream, not a
reason to avoid this.

And **ood-api has not been tested in this configuration**; the section below
records what we established about CILogon's token format, not a working
deployment.

### CILogon

CILogon issues opaque access tokens by default. We confirmed this by running a
device-code grant against a CILogon client registered for an ACCESS-CI site: the
`access_token` came back as a 196-character base32 string with no dots, while
the `id_token` in the same response was a normal JWT. The opaque token
validates through `https://cilogon.org/oauth2/introspect`, which returns
`active: true` along with `client_id`, `exp`, `iat`, `iss`, `jti`, `nbf`,
`scope`, `token_type` and `username`.

This is not universal to CILogon. Its underlying OA4MP software issues a JWT
access token when a *token handler* is configured for the client, and an opaque
one when it is not — CILogon documents JWT issuance (SciTokens, WLCG, RFC 9068,
GA4GH Passports) as a [Full Service subscription feature](https://www.cilogon.org/jwt).
The LIGO/IGWN virtual issuer at `https://cilogon.org/igwn` demonstrably issues
JWT access tokens. So the answer depends on how CILogon has configured your
client, and it is not something you can change from your end by adjusting
scopes or registration options.

Two practical consequences:

- **Discovery does not advertise the access-token format.** Neither the base
  issuer nor `igwn` publishes `access_token_signing_alg_values_supported`, so
  there is no field that answers this directly — request a token and look at
  it. A JWT-issuing tenant *is* distinguishable in other ways, notably its own
  `jwks_uri` (`https://cilogon.org:443/oauth2/certs/igwn` rather than
  `/oauth2/certs`), but that only tells you a tenant exists. It cannot tell you
  whether your client on the base issuer has a token handler configured, which
  is the case that matters for ACCESS-CI sites.
- **ACCESS-CI clients are on the base `https://cilogon.org` issuer** — there is
  no `access` virtual issuer — so they get opaque tokens unless CILogon has
  configured a handler for that specific client.

To check your own client, request a token and inspect its shape. A JWT starts
with `ey` and has exactly two dots; anything else is opaque:

Needs `jq`, which is not installed on a stock RHEL-family OOD host
(`dnf install jq`).

```bash
CLIENT_ID='cilogon:/client_id/YOUR_CLIENT_ID'
CLIENT_SECRET='YOUR_CLIENT_SECRET'

# Device-code grant, so no callback server is needed.
RESP=$(curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  --data-urlencode 'scope=openid email profile org.cilogon.userinfo' \
  https://cilogon.org/oauth2/device_authorization)
DEVICE_CODE=$(echo "$RESP" | jq -r .device_code)
echo "$RESP" | jq -r .verification_uri_complete
```

Open that URL and approve in a browser. **Then** run the exchange — running it
first returns `authorization_pending`, which is expected rather than an error:

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
  -d "device_code=$DEVICE_CODE" \
  https://cilogon.org/oauth2/token \
  | jq -r 'if .access_token == null then "not yet: \(.error)"
           elif (.access_token | startswith("ey")) and (.access_token | split(".") | length) == 3
           then "JWT" else "OPAQUE (\(.access_token | length) chars)" end'
```

`OPAQUE` means the JWKS methods above will not work for this client.

If the result is opaque and you need bearer-token API access, the options are
to ask CILogon whether a token handler can be configured for your client, or to
front ood-api with an IdP that issues JWTs. Open OnDemand's own
[ACCESS authentication guide](https://osc.github.io/ood-documentation/latest/authentication/nsf-access.html)
configures browser SSO only and does not cover bearer-token validation, so
there is no established recipe for this upstream.

## Token lifecycle (partly untested)

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
the job environment. The grant itself works against CILogon — we used it
to obtain a real token, as described under
[CILogon](#cilogon) — but the resulting token has not been exercised against
ood-api.

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

Verify the `iss` (issuer) and `exp` (expiration) fields, and that `aud`
names a client ID listed in a `Require claim aud:` line. A valid token
issued to a client you have not listed gets a 401 by design.

**Check the JWKS URI:** Confirm Apache can reach it:

```bash
curl -s https://your-idp/certs | python3 -m json.tool
```

### Discovery document returns 404

Check that the `AliasMatch` directive is in your Apache config:

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
