# OOD MCP Server

MCP (Model Context Protocol) server for interacting with HPC clusters through the OOD API.

## Setup

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

## Configuration

| Variable | Required | Description |
|----------|----------|-------------|
| `OOD_API_URL` | No | Base URL of OOD API (default: `http://localhost:3000`) |
| `OOD_API_TOKEN` | Yes | API bearer token |

## Usage

```bash
OOD_API_URL=https://ondemand.example.edu/pun/sys/ood-api \
OOD_API_TOKEN=your-token-here \
python server.py
```

## MCP Client Configuration

Example configuration for MCP clients:

```json
{
  "command": "/path/to/venv/bin/python",
  "args": ["/path/to/server.py"],
  "env": {
    "OOD_API_URL": "https://ondemand.example.edu/pun/sys/ood-api",
    "OOD_API_TOKEN": "your-token-here"
  }
}
```

## Available Tools

| Tool | Description |
|------|-------------|
| `list_clusters` | List all available HPC clusters |
| `get_cluster` | Get details about a specific cluster |
| `list_jobs` | List jobs on a cluster for the current user |
| `get_job` | Get details about a specific job |
| `submit_job` | Submit a new batch job |
| `cancel_job` | Cancel a running or queued job |
