# OOD API

## Overview

OOD API is an Open OnDemand Passenger app that provides a REST API and Model Context Protocol (MCP) endpoint for programmatic access to HPC cluster resources. It is designed for researchers, developers, and AI assistants that need to interact with HPC systems without a browser — submitting jobs, managing files, querying clusters, and inspecting the runtime environment via HTTP or MCP.

An optional Dashboard plugin provides a token management UI for sites using application-level authentication.

- Upstream project: [Model Context Protocol](https://modelcontextprotocol.io/)
- Repository: [Sweet-and-Fizzy/ood-api](https://github.com/Sweet-and-Fizzy/ood-api)

## Screenshots

This is a headless API with no end-user UI. The optional Dashboard plugin adds a token management page at `/settings/api_tokens`.

## Features

- REST API and built-in MCP endpoint for clusters, jobs, files, environment variables, and site context
- 19 MCP tools + 1 resource — agents can discover accounts/queues, submit jobs with dependencies, hold/release jobs, view job history, read/write/append files, and query the runtime environment
- Structured audit logging (key=value to stderr) for all operations across both REST and MCP
- Site-operator-managed agent context (`/etc/ood/config/agents.d/*.md`) exposed as an MCP resource
- Two authentication modes: Apache JWT validation (CILogon, Keycloak) or application-level tokens
- Per-user isolation via OOD's existing PUN architecture
- All scheduler operations use the `ood_core` abstraction layer — works with Slurm, PBS, LSF, etc.
- Optional Dashboard plugin for token management (OOD 4.0+)
- No browser session required when using Apache JWT validation

## Requirements

### Compute Node Software

No compute node software is required. The API runs on the OOD host and communicates with clusters via `ood_core`.

### Open OnDemand

- Open OnDemand 3.x or 4.x
- Open OnDemand 4.0+ required for Dashboard plugin (token management UI)

### Optional

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

For sites using CILogon, Keycloak, or other OIDC providers with a JWKS endpoint. Enables both browser login and bearer token access for API and MCP clients.

Edit `/etc/ood/config/ood_portal.yml`:

```yaml
auth:
  - "AuthType auth-openidc"
  - "Require valid-user"
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://cilogon.org/oauth2/certs"
  OIDCOAuthRemoteUserClaim: "sub"
```

The `auth` override switches from `openid-connect` (browser sessions only) to `auth-openidc` (sessions + bearer tokens). This is the same Apache module — browser login works exactly as before. See [MCP Authentication](docs/mcp-oauth.md) for the full guide, including automatic OAuth discovery for MCP clients.

Then regenerate the Apache config:

```bash
sudo /opt/ood/ood-portal-generator/sbin/update_ood_portal
sudo systemctl restart httpd
```

#### Option B: Application-Level Tokens

For REST API access from scripts with an active browser session. Not usable by MCP clients (Apache blocks requests without a session cookie or valid JWT). Requires OOD 4.0+ for the Dashboard plugin.

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

### 3. MCP Endpoint

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

MCP clients authenticate via JWT bearer tokens validated by Apache. This requires the `auth` override described in Option A above. See [MCP Authentication](docs/mcp-oauth.md) for two setup methods: static bearer tokens (minimal config) or automatic OAuth discovery (best UX).

File size limits (`OOD_API_MAX_FILE_READ`, `OOD_API_MAX_FILE_WRITE`), allowed path roots, and the environment-variable allowlist apply to **both** REST and MCP — MCP tools return an error response in the protocol instead of HTTP status codes like 413.

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

### Environment Variables (API)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OOD_CLUSTERS` | No | `/etc/ood/config/clusters.d` | Path to cluster config directory |
| `OOD_API_MAX_FILE_READ` | No | `10485760` (10 MB) | Maximum file read size in bytes (REST and MCP `read_file`) |
| `OOD_API_MAX_FILE_WRITE` | No | `52428800` (50 MB) | Maximum file write body size in bytes (REST `PUT` and MCP `write_file`) |
| `OOD_API_ENV_ALLOWLIST` | No | See [docs/api.md](docs/api.md#environment-variable-allowlist) | Comma-separated allowlist for env vars endpoint. Entries ending in `*` are prefix matches. |
| `OOD_API_CONTEXT_PATH` | No | `/etc/ood/config/agents.d` | Path to directory containing site-specific agent context files (*.md) |

## Architecture

```
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│    curl /    │ │   Scripts    │ │  MCP Client  │
│   Postman    │ │   CI/CD      │ │   (Claude)   │
└──────┬───────┘ └──────┬───────┘ └──────┬───────┘
       │                │                │
       │   HTTP + Bearer Token           │ MCP Protocol (HTTP)
       └────────────────┴────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                         Apache                              │
│           mod_auth_openidc (OIDC / JWT validation)          │
└─────────────────────────────┬───────────────────────────────┘
                              │ REMOTE_USER
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Per-User Nginx (PUN)                      │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                   OOD API (Sinatra)                   │  │
│  │  ┌─────────────────┐    ┌──────────────────────────┐  │  │
│  │  │   REST Routes    │    │   MCP Transport (/mcp)   │  │  │
│  │  │  /api/v1/*      │    │   19 tools + 1 resource  │  │  │
│  │  └────────┬────────┘    └────────────┬─────────────┘  │  │
│  │           └──────────┬───────────────┘                │  │
│  │                      ▼                                │  │
│  │              Handler Layer                            │  │
│  │     Clusters │ Jobs │ Files │ Env │ Context           │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────┬───────────────────────────────┘
                              │ ood_core
                              ▼
┌─────────────────────────────────────────────────────────────┐
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
| GET | `/api/v1/jobs/historic?cluster=X` | List completed jobs |
| POST | `/api/v1/jobs/:id/hold?cluster=X` | Hold a queued job |
| POST | `/api/v1/jobs/:id/release?cluster=X` | Release a held job |
| GET | `/api/v1/files?path=X` | List directory or get file info |
| GET | `/api/v1/files/content?path=X` | Read file contents |
| POST | `/api/v1/files?path=X&type=directory` | Create directory |
| PUT | `/api/v1/files?path=X` | Write file contents |
| DELETE | `/api/v1/files?path=X` | Delete file or directory |
| GET | `/api/v1/env` | List allowed environment variables |
| GET | `/api/v1/env/:name` | Get single environment variable |
| GET | `/api/v1/context` | Get site-specific agent context |
| GET | `/api/v1/accounts?cluster=X` | List accounts for job submission |
| GET | `/api/v1/queues?cluster=X` | List queues/partitions |
| GET | `/api/v1/cluster_info?cluster=X` | Get cluster resource utilization |

See [docs/api.md](docs/api.md) for full API documentation.

### MCP Tools

| Tool | Description |
|------|-------------|
| `list_clusters` | List available HPC clusters |
| `get_cluster` | Get cluster details |
| `list_accounts` | List accounts available for job submission |
| `list_queues` | List queues/partitions on a cluster |
| `get_cluster_info` | Get cluster resource utilization (nodes, CPUs, GPUs) |
| `list_jobs` | List user's active jobs on a cluster |
| `get_job` | Get job details |
| `list_historic_jobs` | List completed jobs from accounting database |
| `submit_job` | Submit a batch job (supports dependencies) |
| `cancel_job` | Cancel a job |
| `hold_job` | Put a queued job on hold |
| `release_job` | Release a held job |
| `list_files` | List directory contents |
| `read_file` | Read file contents (supports max_size limit) |
| `write_file` | Write or append content to a file |
| `create_directory` | Create a new directory |
| `delete_file` | Delete a file or directory |
| `list_env` | List allowed environment variables |
| `get_env` | Get a single environment variable |

### MCP Resources

| Resource | URI | Description |
|----------|-----|-------------|
| Cluster Context | `ood://context` | Site-specific policies and guidelines from `/etc/ood/config/agents.d/` |

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

### Local development server

```bash
bundle exec ruby bin/dev
```

Starts Puma directly, serving both the REST API and MCP endpoint at `http://localhost:9292`. See `docs/development.md` for the full OOD dev container setup.

**Note:** When running locally without a reverse proxy, the `/mcp` endpoint is unauthenticated. In production, Apache + mod_auth_openidc handles authentication for both REST and MCP.

### Running the test suite

```bash
bundle exec rake test
```

## Known Limitations

- Application-level tokens (Option B) require an active browser session to spawn the PUN
- PUN cleanup cron runs every 2 hours by default — long-running API workflows may need this adjusted
- Dashboard plugin requires OOD 4.0+
- MCP transport runs in stateless mode — server-initiated notifications are not supported (tool list is static, so this has no practical impact)
- Job history, hold/release, and dependencies are scheduler-dependent — not all schedulers support all features
- Account discovery, queue listing, cluster info, and historic jobs are only fully supported on Slurm — other schedulers may return empty results or errors for these operations
- Historic job listings are **filtered to the authenticated user** (`job_owner` must match); the raw accounting API may return broader data on some schedulers
- Audit log output goes to stderr (PUN error.log) — no dedicated log file or rotation beyond OS logrotate

## Contributing

Contributions are welcome. To contribute:

1. Fork this repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Submit a pull request with a description of your changes

For bugs or feature requests, [open an issue](https://github.com/Sweet-and-Fizzy/ood-api/issues).

This app is part of the [OOD Appverse](https://openondemand.connectci.org/affinity-groups/ood-appverse). Join the Appverse Affinity Group to connect with other contributors.

## References

- [Model Context Protocol](https://modelcontextprotocol.io/) — the AI assistant protocol used by the built-in MCP endpoint
- [Open OnDemand](https://openondemand.org/) — the HPC portal framework
- [Sinatra](https://sinatrarb.com/) — the Ruby web framework powering the REST API
- [CILogon](https://www.cilogon.org/) — identity provider commonly used with OOD

## License

[MIT License](LICENSE)

## Acknowledgments

Testing supported by Wake Forest University and the University of Kentucky.
