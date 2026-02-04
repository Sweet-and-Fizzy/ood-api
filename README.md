# OOD API

REST API and MCP server for Open OnDemand, providing programmatic access to HPC clusters.

## Overview

This project provides:

1. **REST API** - A Sinatra app that exposes HPC job management via HTTP
2. **MCP Server** - A [Model Context Protocol](https://modelcontextprotocol.io/) server for AI assistants
3. **Dashboard Plugin** - Token management UI for the OOD Dashboard

## Requirements

- Open OnDemand 3.1+
- Ruby 3.0+
- Python 3.10+ (for MCP server)

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

This adds a token management UI to the Dashboard:

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

## Authentication

The API uses Bearer token authentication. Tokens are stored in `~/.config/ondemand/tokens.json`.

### Creating Tokens

**Via Dashboard** (if plugin installed):
1. Go to `/settings/api_tokens`
2. Enter a name and click "Generate Token"
3. Copy the token immediately

**Manually:**
```bash
mkdir -p ~/.config/ondemand
TOKEN=$(python -c "import secrets; print(secrets.token_hex(32))")
cat > ~/.config/ondemand/tokens.json << EOF
[{"id": "$(uuidgen)", "name": "My Token", "token": "$TOKEN", "created_at": "$(date -Iseconds)"}]
EOF
chmod 600 ~/.config/ondemand/tokens.json
echo "Your token: $TOKEN"
```

### Using Tokens

```bash
curl -H "Authorization: Bearer YOUR_TOKEN" \
  https://ondemand.example.edu/pun/sys/ood-api/api/v1/clusters
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

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   MCP Client (Claude, etc.)                 │
└─────────────────────────────┬───────────────────────────────┘
                              │ MCP Protocol
┌─────────────────────────────▼───────────────────────────────┐
│                        MCP Server                           │
│                      (mcp/server.py)                        │
└─────────────────────────────┬───────────────────────────────┘
                              │ HTTP/REST
┌─────────────────────────────▼───────────────────────────────┐
│                         OOD API                             │
│                       (app/api.rb)                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Per-User Nginx (PUN)                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────┬───────────────────────────────┘
                              │ ood_core
┌─────────────────────────────▼───────────────────────────────┐
│                      HPC Clusters                           │
│                  (Slurm, PBS, LSF, etc.)                    │
└─────────────────────────────────────────────────────────────┘

Dashboard Plugin (optional):
┌─────────────────────────────────────────────────────────────┐
│                     OOD Dashboard                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │   /settings/api_tokens  (token management UI)        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

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
