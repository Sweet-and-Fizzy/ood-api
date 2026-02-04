# Open OnDemand REST API

The Open OnDemand REST API provides programmatic access to HPC resources through OOD's scheduler abstraction layer. This API is designed for AI agents, automation scripts, and external tools that need to submit and manage jobs without using the web interface.

## Table of Contents

- [Overview](#overview)
- [Authentication](#authentication)
- [API Reference](#api-reference)
  - [Clusters](#clusters)
  - [Jobs](#jobs)
- [Error Handling](#error-handling)
- [Examples](#examples)
- [Security Considerations](#security-considerations)

## Overview

The API provides:

- **Cluster Discovery**: List available HPC clusters and their configurations
- **Job Management**: Submit, monitor, and cancel batch jobs
- **Token Authentication**: Secure, user-scoped API tokens

Key characteristics:

- RESTful JSON API at `/api/v1/`
- Bearer token authentication
- Uses OOD's existing scheduler adapters (Slurm, PBS, LSF, etc.)

## Authentication

The API uses Bearer token authentication. Users generate tokens through the OOD web interface and include them in API requests.

### Generating a Token

1. Log in to Open OnDemand
2. Navigate to **Settings > API Tokens** (`/settings/api_tokens`)
3. Enter a descriptive name for your token (e.g., "My Script", "CI Pipeline")
4. Click **Generate Token**
5. **Copy the token immediately** - it will only be shown once

### Using a Token

Include the token in the `Authorization` header of all API requests:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  https://ondemand.example.com/api/v1/clusters
```

### Token Storage

Tokens are stored in the user's home directory at `~/.config/ondemand/tokens.json` with `600` permissions (readable only by the owner). Each token includes:

- Unique ID
- User-defined name
- Creation timestamp
- Last used timestamp

### Revoking Tokens

Tokens can be revoked through the web interface at **Settings > API Tokens**. Revoked tokens are immediately invalidated.

## API Reference

All endpoints return JSON responses with the following structure:

**Success Response:**
```json
{
  "data": { ... }
}
```

**Error Response:**
```json
{
  "error": "not_found",
  "message": "Cluster not found"
}
```

### Clusters

#### List Clusters

Returns all available HPC clusters that allow job submission.

```
GET /api/v1/clusters
```

**Response:**
```json
{
  "data": [
    {
      "id": "owens",
      "title": "Owens Cluster",
      "adapter": "slurm",
      "login_host": "owens.osc.edu"
    },
    {
      "id": "pitzer",
      "title": "Pitzer Cluster",
      "adapter": "slurm",
      "login_host": "pitzer.osc.edu"
    }
  ]
}
```

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/api/v1/clusters
```

#### Get Cluster

Returns details for a specific cluster.

```
GET /api/v1/clusters/:id
```

**Parameters:**
- `id` (path) - Cluster identifier

**Response:**
```json
{
  "data": {
    "id": "owens",
    "title": "Owens Cluster",
    "adapter": "slurm",
    "login_host": "owens.osc.edu"
  }
}
```

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/api/v1/clusters/owens
```

### Jobs

#### List Jobs

Returns all jobs for the authenticated user on a specified cluster.

```
GET /api/v1/jobs?cluster=:cluster_id
```

**Parameters:**
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": [
    {
      "job_id": "12345",
      "cluster": "owens",
      "job_name": "my-simulation",
      "job_owner": "alice",
      "status": "running",
      "queue_name": "batch",
      "accounting_id": "PAS1234",
      "submitted_at": "2024-01-15T10:30:00Z",
      "started_at": "2024-01-15T10:35:00Z",
      "wallclock_time": 1800,
      "wallclock_limit": 3600
    }
  ]
}
```

**Job Status Values:**
- `queued` - Job is waiting in queue
- `queued_held` - Job is held in queue
- `running` - Job is executing
- `suspended` - Job execution is suspended
- `completed` - Job has finished

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/api/v1/jobs?cluster=owens"
```

#### Get Job

Returns details for a specific job.

```
GET /api/v1/jobs/:id?cluster=:cluster_id
```

**Parameters:**
- `id` (path) - Job identifier
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": {
    "job_id": "12345",
    "cluster": "owens",
    "job_name": "my-simulation",
    "job_owner": "alice",
    "status": "running",
    "queue_name": "batch",
    "accounting_id": "PAS1234",
    "submitted_at": "2024-01-15T10:30:00Z",
    "started_at": "2024-01-15T10:35:00Z",
    "wallclock_time": 1800,
    "wallclock_limit": 3600
  }
}
```

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/api/v1/jobs/12345?cluster=owens"
```

#### Submit Job

Submits a new job to the specified cluster. Unlike other job endpoints that use a query parameter, the cluster is specified in the JSON request body.

```
POST /api/v1/jobs
Content-Type: application/json
```

**Request Body:**
```json
{
  "cluster": "owens",
  "script": {
    "content": "#!/bin/bash\n#SBATCH --nodes=1\necho 'Hello World'",
    "workdir": "/users/alice/project"
  },
  "options": {
    "job_name": "my-job",
    "queue_name": "batch",
    "accounting_id": "PAS1234",
    "wall_time": 3600,
    "native": ["-N", "2"]
  }
}
```

**Request Fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `cluster` | string | Yes | Target cluster ID |
| `script.content` | string | Yes | Job script content |
| `script.workdir` | string | No | Working directory for the job |
| `options.job_name` | string | No | Name for the job |
| `options.queue_name` | string | No | Queue/partition to submit to |
| `options.accounting_id` | string | No | Account/project to charge |
| `options.wall_time` | integer | No | Wall time limit in seconds |
| `options.output_path` | string | No | Path for stdout |
| `options.error_path` | string | No | Path for stderr |
| `options.native` | array | No | Native scheduler arguments |

**Response (201 Created):**
```json
{
  "data": {
    "job_id": "12346",
    "cluster": "owens",
    "job_name": "my-job",
    "status": "queued",
    ...
  }
}
```

**Example:**
```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "cluster": "owens",
    "script": {
      "content": "#!/bin/bash\necho Hello World",
      "workdir": "/users/alice/project"
    },
    "options": {
      "job_name": "test-job",
      "wall_time": 300
    }
  }' \
  https://ondemand.example.com/api/v1/jobs
```

#### Cancel Job

Cancels a running or queued job.

```
DELETE /api/v1/jobs/:id?cluster=:cluster_id
```

**Parameters:**
- `id` (path) - Job identifier
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": {
    "job_id": "12345",
    "status": "cancelled"
  }
}
```

**Example:**
```bash
curl -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/api/v1/jobs/12345?cluster=owens"
```

## Error Handling

The API uses standard HTTP status codes:

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created (job submitted) |
| 400 | Bad Request (missing/invalid parameters) |
| 401 | Unauthorized (missing/invalid token) |
| 404 | Not Found (cluster/job doesn't exist) |
| 422 | Unprocessable Entity (job submission/cancellation failed) |
| 500 | Internal Server Error |
| 503 | Service Unavailable (scheduler communication error) |

**Error Response Format:**
```json
{
  "error": "not_found",
  "message": "Cluster not found"
}
```

**Error Types:**

| Error | HTTP Code | Description |
|-------|-----------|-------------|
| `bad_request` | 400 | Missing or invalid parameters |
| `unauthorized` | 401 | Invalid or missing API token |
| `not_found` | 404 | Resource not found |
| `unprocessable_entity` | 422 | Request understood but could not be processed |
| `service_unavailable` | 503 | Scheduler communication error |

## Examples

### Python Example

```python
import requests

BASE_URL = "https://ondemand.example.com"
TOKEN = "your-api-token-here"

headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

# List clusters
response = requests.get(f"{BASE_URL}/api/v1/clusters", headers=headers)
clusters = response.json()["data"]
print(f"Available clusters: {[c['id'] for c in clusters]}")

# Submit a job
job_data = {
    "cluster": "owens",
    "script": {
        "content": "#!/bin/bash\necho 'Hello from API'",
        "workdir": "/users/alice/project"
    },
    "options": {
        "job_name": "api-test",
        "wall_time": 300
    }
}

response = requests.post(
    f"{BASE_URL}/api/v1/jobs",
    headers=headers,
    json=job_data
)

if response.status_code == 201:
    job = response.json()["data"]
    print(f"Submitted job: {job['job_id']}")
else:
    print(f"Error: {response.json()['message']}")

# Check job status
job_id = job["job_id"]
response = requests.get(
    f"{BASE_URL}/api/v1/jobs/{job_id}?cluster=owens",
    headers=headers
)
status = response.json()["data"]["status"]
print(f"Job {job_id} status: {status}")

# Cancel job
response = requests.delete(
    f"{BASE_URL}/api/v1/jobs/{job_id}?cluster=owens",
    headers=headers
)
print(f"Job cancelled: {response.json()['data']['status']}")
```

### Shell Script Example

```bash
#!/bin/bash

BASE_URL="https://ondemand.example.com"
TOKEN="your-api-token-here"

# List clusters
echo "Available clusters:"
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE_URL/api/v1/clusters" | jq '.data[].id'

# Submit a job
JOB_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "cluster": "owens",
    "script": {
      "content": "#!/bin/bash\nsleep 60\necho done"
    },
    "options": {
      "job_name": "api-test",
      "wall_time": 300
    }
  }' \
  "$BASE_URL/api/v1/jobs")

JOB_ID=$(echo $JOB_RESPONSE | jq -r '.data.job_id')
echo "Submitted job: $JOB_ID"

# Poll for completion
while true; do
  STATUS=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/jobs/$JOB_ID?cluster=owens" | jq -r '.data.status')

  echo "Job status: $STATUS"

  if [ "$STATUS" = "completed" ]; then
    echo "Job finished!"
    break
  fi

  sleep 10
done
```

## Security Considerations

### Token Security

- Tokens are stored with `600` permissions (owner read/write only)
- Tokens are 64-character hex strings (256 bits of entropy)
- Token comparison uses timing-safe algorithms to prevent timing attacks
- Tokens can be revoked immediately through the web interface

### Access Control

- Each token inherits the permissions of the user who created it
- API requests execute with the same authorization as the token owner
- Jobs are submitted as the authenticated user

### Best Practices

1. **Rotate tokens regularly** - Create new tokens and revoke old ones periodically
2. **Use descriptive names** - Name tokens by their purpose for easy auditing
3. **Limit token exposure** - Store tokens securely, never commit to version control
4. **Monitor usage** - Check "last used" timestamps in the token management UI
5. **Revoke unused tokens** - Remove tokens that are no longer needed

### Network Security

- Always use HTTPS in production
- The API respects OOD's existing authentication and authorization framework
- Consider network-level restrictions (firewall, VPN) for API access

## MCP Server

An [MCP (Model Context Protocol)](https://modelcontextprotocol.io/) server is provided for integration with AI assistants and other MCP-compatible clients.

See the [MCP Server documentation](../mcp/README.md) for setup instructions.

## Future Enhancements

The following features are planned for future releases:

- **Token scopes** - Limit tokens to specific operations (read-only, jobs-only, etc.)
- **Token expiration** - Automatic token expiration after a configured period
- **Queue/account discovery** - Endpoints to list available queues and accounts
- **Batch status checks** - Check multiple job statuses in a single request
- **Rate limiting** - Per-token rate limits to prevent abuse
