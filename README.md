# OOD API

REST API and MCP server for Open OnDemand, providing programmatic access to HPC clusters.

## Overview

This project provides:

1. **REST API** - A Sinatra app that exposes HPC resources via HTTP
2. **MCP Server** - A [Model Context Protocol](https://modelcontextprotocol.io/) server for AI assistants
3. **Dashboard Plugin** - Token management UI (only needed for application-level tokens)

**API Capabilities:**

- **Clusters** - List and query available HPC clusters
- **Jobs** - List, submit, monitor, and cancel batch jobs
- **Files** - List, read, write, and delete files on the cluster

## Architecture

```
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│    curl /    │ │   Scripts    │ │  MCP Client  │
│   Postman    │ │   CI/CD      │ │   (Claude)   │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       │                │                │ MCP Protocol
       │                │                ▼
       │                │       ┌──────────────────┐
       │                │       │    MCP Server    │
       │                │       │  (mcp/server.py) │
       │                │       └────────┬─────────┘
       │                │                │
       └────────────────┴────────────────┘
                        │
                        │ HTTP + Bearer Token
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                         Apache                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              mod_auth_openidc                       │    │
│  │                                                     │    │
│  │  Option 1: Validate JWT via JWKS (CILogon, etc.)    │    │
│  │  Option 2: Pass through to app-level auth           │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────┬───────────────────────────────┘
                              │ REMOTE_USER
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      pun_proxy.lua                          │
│           (maps user → PUN socket, spawns if needed)        │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│                   Per-User Nginx (PUN)                      │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                     OOD API                         │    │
│  │                   (app/api.rb)                      │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────┬───────────────────────────────┘
                              │ ood_core
┌─────────────────────────────▼───────────────────────────────┐
│                      HPC Clusters                           │
│                  (Slurm, PBS, LSF, etc.)                    │
└─────────────────────────────────────────────────────────────┘
```

## Requirements

- Open OnDemand (tested with 3.x and 4.x)
- Open OnDemand 4.0+ required for Dashboard plugin (token management UI)
- Python 3.10+ (for MCP server)

## Authentication

The API supports two authentication methods:

### Option 1: Apache JWT Validation (Recommended)

For sites using CILogon, Keycloak, or other OIDC providers that publish a JWKS endpoint, you can configure Apache to validate JWT bearer tokens directly. This is the preferred approach as it uses your existing identity provider.

**How it works:**

1. `mod_auth_openidc` (already used by OOD for browser auth) has a built-in Resource Server mode
2. It downloads the IdP's public keys from the JWKS endpoint
3. Validates JWT signatures and claims locally
4. Sets `REMOTE_USER` from the token's `sub` or `preferred_username` claim
5. `pun_proxy.lua` routes the request to the user's PUN (spawning it if needed)

**Configuration** in `/etc/ood/config/ood_portal.yml`:

```yaml
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://cilogon.org/oauth2/certs"
  OIDCOAuthRemoteUserClaim: "sub"
  # OIDCOAuthVerifyCertFiles: "/path/to/cert.pem"  # Optional, for additional verification
```

Then regenerate the Apache config:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

**Usage:**

```bash
# Obtain a token from your IdP (e.g., CILogon)
curl -H "Authorization: Bearer <your-jwt-token>" \
  https://ondemand.example.edu/pun/sys/ood-api/api/v1/clusters
```

With this approach, no browser login is required. The PUN is spawned on first API request.

### Option 2: Application-Level Tokens

For sites using Dex or other IdPs that don't support JWKS/introspection, this API provides its own token management. Tokens are stored in `~/.config/ondemand/tokens.json`.

**Note:** This approach requires an active browser session to spawn the PUN (see [Session and PUN Lifecycle](#session-and-pun-lifecycle)).

**Creating Tokens:**

*Via Dashboard* (if plugin installed):
1. Go to `/settings/api_tokens`
2. Enter a name and click "Generate Token"
3. Copy the token immediately

*Manually:*
```bash
mkdir -p ~/.config/ondemand
TOKEN=$(python -c "import secrets; print(secrets.token_hex(32))")
cat > ~/.config/ondemand/tokens.json << EOF
[{"id": "$(uuidgen)", "name": "My Token", "token": "$TOKEN", "created_at": "$(date -Iseconds)"}]
EOF
chmod 600 ~/.config/ondemand/tokens.json
echo "Your token: $TOKEN"
```

**Usage:**

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://ondemand.example.edu/pun/sys/ood-api/api/v1/clusters
```

## Installation

### 1. Install the API App

```bash
cd /var/www/ood/apps/sys
git clone https://github.com/OSC/ood-api.git
cd ood-api
bundle install --path vendor/bundle
```

The API will be available at `https://ondemand.example.edu/pun/sys/ood-api/`

### 2. Install the Dashboard Plugin (Optional)

Only needed if using application-level tokens (Option 2 authentication). Skip this if using Apache JWT validation with CILogon/Keycloak.

```bash
ln -s /var/www/ood/apps/sys/ood-api/dashboard-plugin /etc/ood/config/plugins/ood-api
```

Restart the PUN or web server. Token management will be available at `/settings/api_tokens`.

### 3. Install the MCP Server (Optional)

```bash
cd /var/www/ood/apps/sys/ood-api/mcp
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Configure your MCP client:

```json
{
  "command": "/var/www/ood/apps/sys/ood-api/mcp/venv/bin/python",
  "args": ["/var/www/ood/apps/sys/ood-api/mcp/server.py"],
  "env": {
    "OOD_API_URL": "https://ondemand.example.edu/pun/sys/ood-api",
    "OOD_API_TOKEN": "your-token-here"
  }
}
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check (no auth) |
| GET | `/api/v1/clusters` | List available clusters |
| GET | `/api/v1/clusters/:id` | Get cluster details |
| GET | `/api/v1/jobs?cluster=X` | List user's jobs |
| GET | `/api/v1/jobs/:id?cluster=X` | Get job details |
| POST | `/api/v1/jobs` | Submit a job |
| DELETE | `/api/v1/jobs/:id?cluster=X` | Cancel a job |
| GET | `/api/v1/files?path=X` | List directory or get file info |
| GET | `/api/v1/files/content?path=X` | Read file contents |
| POST | `/api/v1/files?path=X&type=directory` | Create directory |
| PUT | `/api/v1/files?path=X` | Write file contents |
| DELETE | `/api/v1/files?path=X` | Delete file or directory |

See [docs/api.md](docs/api.md) for full API documentation.

## MCP Tools

| Tool | Description |
|------|-------------|
| `list_clusters` | List available HPC clusters |
| `get_cluster` | Get cluster details |
| `list_jobs` | List jobs on a cluster |
| `get_job` | Get job details |
| `submit_job` | Submit a batch job |
| `cancel_job` | Cancel a job |
| `list_files` | List directory contents |
| `read_file` | Read file contents |
| `write_file` | Write content to a file |
| `create_directory` | Create a new directory |
| `delete_file` | Delete a file or directory |

## Session and PUN Lifecycle

The API runs within OOD's Per-User Nginx (PUN) architecture.

### With Apache JWT Validation (Option 1)

When using Apache-layer JWT validation, **no browser session is required**:

1. Bearer token arrives with API request
2. `mod_auth_openidc` validates the JWT using the IdP's JWKS keys
3. Apache sets `REMOTE_USER` from the token claims
4. `pun_proxy.lua` spawns the user's PUN if it doesn't exist
5. Request is proxied to the PUN

The PUN is spawned on-demand. Nothing changes in the security model - requests still run as the authenticated user's UID with full per-user isolation.

### With Application-Level Tokens (Option 2)

When using application-level tokens, the PUN must already be running:

1. **Initial Setup**: User must log into OOD Dashboard via browser to start their PUN
2. **API Access**: Application-level tokens authenticate requests within the PUN
3. **PUN Cleanup**: The cron job (`nginx_stage nginx_clean`) runs every 2 hours and stops idle PUNs

### Session Timeouts

| Component | Default | Configurable |
|-----------|---------|--------------|
| OIDC Session | 8 hours inactivity / 8 hours max | `oidc_session_inactivity_timeout` in `ood_portal.yml` |
| PUN Cleanup | Every 2 hours | Edit `/etc/cron.d/ood` to extend or disable |

## Development

```bash
# API
bundle install
OOD_CLUSTERS=/path/to/clusters.d bundle exec rackup -p 9292

# MCP Server
cd mcp && python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
OOD_API_URL=http://localhost:9292 OOD_API_TOKEN=test python server.py
```

## Testing

### Ruby API Tests

```bash
bundle install
bundle exec rake test
```

### MCP Server Tests

```bash
cd mcp
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pytest test_server.py -v
```

## License

MIT
