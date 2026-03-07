# OOD API

## Overview

OOD API is an Open OnDemand Passenger app that provides a REST API and Model Context Protocol (MCP) server for programmatic access to HPC cluster resources. It is designed for researchers, developers, and AI assistants that need to interact with HPC systems without a browser — submitting jobs, managing files, and querying clusters via HTTP or MCP.

An optional Dashboard plugin provides a token management UI for sites using application-level authentication.

- Upstream project: [Model Context Protocol](https://modelcontextprotocol.io/)
- Repository: [Sweet-and-Fizzy/ood-api](https://github.com/Sweet-and-Fizzy/ood-api)

## Screenshots

This is a headless API with no end-user UI. The optional Dashboard plugin adds a token management page at `/settings/api_tokens`.

## Features

- REST API exposing clusters, jobs, and file operations via HTTP
- MCP server enabling AI assistants (Claude, etc.) to interact with HPC resources
- Two authentication modes: Apache JWT validation (CILogon, Keycloak) or application-level tokens
- Per-user isolation via OOD's existing PUN architecture
- Optional Dashboard plugin for token management (OOD 4.0+)
- No browser session required when using Apache JWT validation

## Requirements

### Compute Node Software

No compute node software is required. The API runs on the OOD host and communicates with clusters via `ood_core`.

### Open OnDemand

- Open OnDemand 3.x or 4.x
- Open OnDemand 4.0+ required for Dashboard plugin (token management UI)

### Optional

- Python 3.10+ (for MCP server)
- `mod_auth_openidc` (already included with OOD; needed for Apache JWT validation)

## App Installation

### 1. Clone the repository

```bash
cd /var/www/ood/apps/sys
git clone https://github.com/Sweet-and-Fizzy/ood-api.git
cd ood-api
bundle install --path vendor/bundle

# Pin to a release (recommended)
# git checkout v1.0.0
```

### 2. Configure for your site

Choose an authentication method:

#### Option A: Apache JWT Validation (Recommended)

For sites using CILogon, Keycloak, or other OIDC providers with a JWKS endpoint. No browser session required for API access.

Edit `/etc/ood/config/ood_portal.yml`:

```yaml
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://cilogon.org/oauth2/certs"
  OIDCOAuthRemoteUserClaim: "sub"
```

Then regenerate the Apache config:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

#### Option B: Application-Level Tokens

For sites using Dex or other IdPs without JWKS support. Requires an active browser session to spawn the PUN.

Install the Dashboard plugin (OOD 4.0+ only):

```bash
ln -s /var/www/ood/apps/sys/ood-api/dashboard-plugin /etc/ood/config/plugins/ood-api
```

Restart the PUN or web server. Token management will be available at `/settings/api_tokens`.

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

### 4. Verify

Restart the app from the OOD developer dashboard, or restart the PUN. Then test:

```bash
curl -H "Authorization: Bearer <your-token>" \
  https://ondemand.example.edu/pun/sys/ood-api/health
```

A successful response confirms the API is running.

## Configuration

### Authentication

| Setting | Location | Description |
|---------|----------|-------------|
| `OIDCOAuthVerifyJwksUri` | `ood_portal.yml` | JWKS endpoint for JWT validation (Option A) |
| `OIDCOAuthRemoteUserClaim` | `ood_portal.yml` | JWT claim to use as username (Option A) |
| Dashboard plugin symlink | `/etc/ood/config/plugins/ood-api` | Enables token management UI (Option B) |

### Session Timeouts

| Component | Default | Configurable |
|-----------|---------|--------------|
| OIDC Session | 8 hours inactivity / 8 hours max | `oidc_session_inactivity_timeout` in `ood_portal.yml` |
| PUN Cleanup | Every 2 hours | Edit `/etc/cron.d/ood` |

### Environment Variables (MCP Server)

| Variable | Required | Description |
|----------|----------|-------------|
| `OOD_API_URL` | Yes | Base URL of the OOD API |
| `OOD_API_TOKEN` | Yes | Bearer token for authentication |

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
│  │  Option A: Validate JWT via JWKS (CILogon, etc.)    │    │
│  │  Option B: Pass through to app-level auth           │    │
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

## API Reference

### REST API Endpoints

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

### MCP Tools

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

## Troubleshooting

### Health check returns 502 or connection refused

1. Verify the app is installed: `ls /var/www/ood/apps/sys/ood-api/`
2. Check that `bundle install` completed successfully
3. Restart the PUN: `sudo /opt/ood/nginx_stage/sbin/nginx_stage nginx_clean`
4. Check PUN logs: `~/ondemand/data/sys/ood-api/` (if they exist) or `/var/log/ondemand-nginx/<user>/`

### 401 Unauthorized with JWT (Option A)

1. Verify `OIDCOAuthVerifyJwksUri` is set correctly in `ood_portal.yml`
2. Confirm the token hasn't expired: `echo '<token>' | cut -d. -f2 | base64 -d | python -m json.tool`
3. Check that the claim in `OIDCOAuthRemoteUserClaim` matches your IdP's token format
4. Check Apache error log: `sudo tail /var/log/httpd/error_log`

### 401 Unauthorized with application-level tokens (Option B)

1. Verify `~/.config/ondemand/tokens.json` exists and is valid JSON
2. Check file permissions: should be `600`
3. Ensure the PUN is running (requires an active browser session first)

### PUN not spawning for API requests

With Option A (JWT), the PUN should spawn automatically. If it doesn't:
1. Verify Apache is setting `REMOTE_USER` by checking the Apache error log for OIDC messages
2. Check that `pun_proxy.lua` is configured to allow the API path

With Option B, the user must log in via browser first to spawn the PUN.

## Testing

| Site | OOD Version | Scheduler | Status |
|------|-------------|-----------|--------|
| University of Kentucky | 3.x | Slurm | Tested |
| Wake Forest University | 4.1 | Slurm | In progress |

To verify your installation:

1. Hit the health endpoint (no auth required): `curl https://ondemand.example.edu/pun/sys/ood-api/health`
2. List clusters with auth: `curl -H "Authorization: Bearer <token>" https://ondemand.example.edu/pun/sys/ood-api/api/v1/clusters`
3. Submit a test job and verify it appears in the scheduler

### Running the test suite

```bash
# Ruby API tests
bundle exec rake test

# MCP Server tests
cd mcp
source venv/bin/activate
pytest test_server.py -v
```

## Known Limitations

- Application-level tokens (Option B) require an active browser session to spawn the PUN
- PUN cleanup cron runs every 2 hours by default — long-running API workflows may need this adjusted
- MCP server requires Python 3.10+
- Dashboard plugin requires OOD 4.0+

## Contributing

Contributions are welcome. To contribute:

1. Fork this repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Submit a pull request with a description of your changes

For bugs or feature requests, [open an issue](https://github.com/Sweet-and-Fizzy/ood-api/issues).

This app is part of the [OOD Appverse](https://openondemand.connectci.org/affinity-groups/ood-appverse). Join the Appverse Affinity Group to connect with other contributors.

## References

- [Model Context Protocol](https://modelcontextprotocol.io/) — the AI assistant protocol used by the MCP server
- [Open OnDemand](https://openondemand.org/) — the HPC portal framework
- [Sinatra](https://sinatrarb.com/) — the Ruby web framework powering the REST API
- [CILogon](https://www.cilogon.org/) — identity provider commonly used with OOD

## License

[MIT License](LICENSE)

## Acknowledgments

Testing supported by Wake Forest University and the University of Kentucky.
