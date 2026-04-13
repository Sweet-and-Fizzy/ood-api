# Open OnDemand REST API

The Open OnDemand REST API provides programmatic access to HPC resources through OOD's scheduler abstraction layer. This API is designed for AI agents, automation scripts, and external tools that need to manage jobs, files, and the runtime environment without using the web interface.

## Table of Contents

- [Overview](#overview)
- [Authentication](#authentication)
- [API Reference](#api-reference)
  - [Clusters](#clusters)
  - [Jobs](#jobs)
  - [Historic Jobs](#historic-jobs)
  - [Files](#files)
  - [Environment Variables](#environment-variables)
  - [Accounts](#accounts)
  - [Queues](#queues)
  - [Cluster Info](#cluster-info)
- [Error Handling](#error-handling)
- [Examples](#examples)
- [Security Considerations](#security-considerations)

## Overview

The API provides:

- **Cluster Discovery**: List available HPC clusters and their configurations
- **Job Management**: Submit, monitor, cancel, hold, and release batch jobs; query historic (completed) jobs
- **File Operations**: Read, write, and manage files on the cluster
- **Environment Discovery**: Inspect allowed environment variables (modules, scheduler settings, paths)
- **Account & Queue Discovery**: List available accounts and queues for job submission
- **Cluster Utilization**: Query active/total nodes, CPUs, and GPUs
- **Flexible Authentication**: Apache JWT validation or application-level tokens

Key characteristics:

- RESTful JSON API at `/api/v1/`
- Bearer token authentication
- Uses OOD's existing scheduler adapters (Slurm, PBS, LSF, etc.)

## Authentication

The API supports two authentication methods. Choose based on your site's identity provider.

### Option 1: Apache JWT Validation (Recommended)

For sites using CILogon, Keycloak, or other OIDC providers that publish a JWKS endpoint, Apache can validate JWT bearer tokens directly. This requires configuration in `ood_portal.yml`:

```yaml
oidc_settings:
  OIDCOAuthVerifyJwksUri: "https://cilogon.org/oauth2/certs"
  OIDCOAuthRemoteUserClaim: "sub"
```

With this configuration:
1. Obtain a JWT from your identity provider
2. Include it in the `Authorization` header:

```bash
curl -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters
```

Apache validates the JWT, sets `REMOTE_USER`, and the request proceeds to the API. No browser session is required.

### Option 2: Application-Level Tokens

For sites using Dex or other IdPs without JWKS support, the API provides its own token management.

**Note:** This requires an active browser session to spawn the user's PUN.

#### Generating a Token

1. Log in to Open OnDemand
2. Navigate to **Settings > API Tokens** (`/settings/api_tokens`)
3. Enter a descriptive name for your token (e.g., "My Script", "CI Pipeline")
4. Click **Generate Token**
5. **Copy the token immediately** - it will only be shown once

#### Using a Token

Include the token in the `Authorization` header of all API requests:

```bash
curl -H "Authorization: Bearer YOUR_TOKEN_HERE" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters
```

#### Token Storage

Tokens are stored in the user's home directory at `~/.config/ondemand/tokens.json` with `600` permissions (readable only by the owner). Each token includes:

- Unique ID
- User-defined name
- Creation timestamp
- Last used timestamp

#### Revoking Tokens

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
      "id": "cluster1",
      "title": "Cluster One",
      "adapter": "slurm",
      "login_host": "login1.example.edu"
    },
    {
      "id": "cluster2",
      "title": "Cluster Two",
      "adapter": "slurm",
      "login_host": "login2.example.edu"
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
    "id": "cluster1",
    "title": "Cluster One",
    "adapter": "slurm",
    "login_host": "login1.example.edu"
  }
}
```

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/api/v1/clusters/cluster1
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
      "cluster": "cluster1",
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
  "https://ondemand.example.com/api/v1/jobs?cluster=cluster1"
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
    "cluster": "cluster1",
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
  "https://ondemand.example.com/api/v1/jobs/12345?cluster=cluster1"
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
  "cluster": "cluster1",
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
| `options.after` | array | No | Job IDs that must start before this job is eligible |
| `options.afterok` | array | No | Job IDs that must complete successfully |
| `options.afternotok` | array | No | Job IDs that must fail |
| `options.afterany` | array | No | Job IDs that must complete (any exit status) |

**Note:** Job dependency options (`after`, `afterok`, `afternotok`, `afterany`) are scheduler-dependent. Not all schedulers support all dependency types. Unsupported dependency types may be silently ignored or cause an error depending on the scheduler adapter.

**Response (201 Created):**
```json
{
  "data": {
    "job_id": "12346",
    "cluster": "cluster1",
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
    "cluster": "cluster1",
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
  "https://ondemand.example.com/api/v1/jobs/12345?cluster=cluster1"
```

#### Hold Job

Places a queued job on hold, preventing it from being scheduled.

```
POST /api/v1/jobs/:id/hold?cluster=:cluster_id
```

**Parameters:**
- `id` (path) - Job identifier
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": {
    "job_id": "12345",
    "status": "queued_held"
  }
}
```

**Example:**
```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/api/v1/jobs/12345/hold?cluster=cluster1"
```

#### Release Job

Releases a held job, allowing it to be scheduled again.

```
POST /api/v1/jobs/:id/release?cluster=:cluster_id
```

**Parameters:**
- `id` (path) - Job identifier
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": {
    "job_id": "12345",
    "status": "queued"
  }
}
```

**Example:**
```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/api/v1/jobs/12345/release?cluster=cluster1"
```

### Historic Jobs

The Historic Jobs API returns completed jobs from the scheduler's accounting database. Unlike the regular jobs endpoint which shows only active jobs, this endpoint returns jobs that have already finished.

#### List Historic Jobs

Returns completed jobs for the authenticated user on a specified cluster.

```
GET /api/v1/jobs/historic?cluster=:cluster_id
```

**Parameters:**
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": [
    {
      "job_id": "12340",
      "cluster": "cluster1",
      "job_name": "old-simulation",
      "job_owner": "alice",
      "status": "completed",
      "queue_name": "batch",
      "accounting_id": "PAS1234",
      "submitted_at": "2024-01-10T08:00:00Z",
      "started_at": "2024-01-10T08:05:00Z",
      "wallclock_time": 3600,
      "wallclock_limit": 7200
    }
  ]
}
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster not found
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/api/v1/jobs/historic?cluster=cluster1"
```

### Files

The Files API provides access to files on the cluster. Access is restricted to the user's home directory and system temp directories.

**Limits (configurable via environment variables):**

| Limit | Default | Environment Variable |
|-------|---------|---------------------|
| Maximum file read | 10 MB | `OOD_API_MAX_FILE_READ` |
| Maximum file write | 50 MB | `OOD_API_MAX_FILE_WRITE` |

Values must be specified in bytes. Example: To allow 100 MB uploads, set `OOD_API_MAX_FILE_WRITE=104857600`.

#### List Directory / Get File Info

List contents of a directory or get metadata for a single file.

```
GET /api/v1/files?path=:path
```

**Parameters:**
- `path` (query, required) - Path to list. Supports `~` expansion.

**Response (directory):**
```json
{
  "data": [
    {
      "path": "/home/alice/project/script.sh",
      "name": "script.sh",
      "directory": false,
      "size": 1234,
      "mode": 33188,
      "owner": "alice",
      "group": "users",
      "mtime": "2024-01-15T10:30:00Z"
    },
    {
      "path": "/home/alice/project/data",
      "name": "data",
      "directory": true,
      "size": null,
      "mode": 16877,
      "owner": "alice",
      "group": "users",
      "mtime": "2024-01-14T09:00:00Z"
    }
  ]
}
```

**Response (single file):**
```json
{
  "data": {
    "path": "/home/alice/script.sh",
    "name": "script.sh",
    "directory": false,
    "size": 1234,
    "mode": 33188,
    "owner": "alice",
    "group": "users",
    "mtime": "2024-01-15T10:30:00Z"
  }
}
```

**Example:**
```bash
# List home directory
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~"

# Get info for specific file
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=/home/alice/script.sh"
```

#### Read File

Read the contents of a file.

```
GET /api/v1/files/content?path=:path[&max_size=:bytes]
```

**Parameters:**
- `path` (query, required) - Path to the file
- `max_size` (query, optional) - Maximum number of bytes to read. Must not exceed the server-configured limit (default 10 MB). Useful for reading only the beginning of large files.

**Response:**
- Content-Type: `application/octet-stream`
- Body: Raw file contents

**Errors:**
- 400 - Cannot read directory, or file too large (exceeds configured max, default 10 MB)
- 403 - Permission denied or path not in allowed directories
- 404 - File not found

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files/content?path=~/script.sh"
```

#### Write File

Write content to a file. Creates the file if it doesn't exist. By default, overwrites the file; use `append=true` to append instead. Parent directories are created automatically.

```
PUT /api/v1/files?path=:path[&append=true]
Content-Type: application/octet-stream
```

**Parameters:**
- `path` (query, required) - Path to the file
- `append` (query, optional) - Set to `true` to append to the file instead of overwriting it

**Request Body:** Raw file contents (max 50 MB)

**Response:**
```json
{
  "data": {
    "path": "/home/alice/newfile.txt",
    "name": "newfile.txt",
    "directory": false,
    "size": 42,
    ...
  }
}
```

**Errors:**
- 400 - Cannot write to directory
- 403 - Permission denied or path not in allowed directories
- 413 - File too large (exceeds configured max, default 50 MB)
- 507 - No space left on device

**Example:**
```bash
curl -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @local_file.txt \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~/remote_file.txt"
```

#### Create Directory

Create a new directory.

```
POST /api/v1/files?path=:path&type=directory
```

**Parameters:**
- `path` (query, required) - Path for the new directory
- `type` (query, required) - Must be `directory`

**Response (201 Created):**
```json
{
  "data": {
    "path": "/home/alice/new_folder",
    "name": "new_folder",
    "directory": true,
    ...
  }
}
```

**Example:**
```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~/new_folder&type=directory"
```

#### Delete File or Directory

Delete a file or directory.

```
DELETE /api/v1/files?path=:path[&recursive=true]
```

**Parameters:**
- `path` (query, required) - Path to delete
- `recursive` (query, optional) - Set to `true` to delete non-empty directories

**Response:**
```json
{
  "data": {
    "path": "/home/alice/old_file.txt",
    "deleted": true
  }
}
```

**Errors:**
- 400 - Directory not empty (when `recursive` is not `true`)
- 403 - Permission denied or path not in allowed directories
- 404 - Path not found

**Example:**
```bash
# Delete a file
curl -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~/old_file.txt"

# Delete a directory recursively
curl -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~/old_folder&recursive=true"
```

#### Path Restrictions

For security, file operations are restricted to:
- User's home directory (`~` or `/home/username`)
- System temp directories (`/tmp`)

Attempts to access paths outside these directories return 403 Forbidden.

### Environment Variables

The Environment Variables API exposes environment variables from the user's PUN process, filtered through a configurable allowlist. This is useful for scripts and automation that need to discover the runtime environment (loaded modules, scheduler settings, paths).

**Security:** Only variables matching the allowlist are exposed. See [Configuration](#environment-variable-allowlist) for details.

#### List Environment Variables

Returns all allowed environment variables as a flat key-value map, sorted alphabetically.

```
GET /api/v1/env[?prefix=:prefix]
```

**Parameters:**
- `prefix` (query, optional) - Filter to variables starting with this prefix. Applied after the allowlist (can only narrow results, never widen).

**Response:**
```json
{
  "data": {
    "HOME": "/home/alice",
    "MODULEPATH": "/opt/modules",
    "SLURM_VERSION": "23.02.6"
  }
}
```

**Example:**
```bash
# Get all allowed env vars
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/env

# Get only SLURM vars
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/env?prefix=SLURM_"
```

#### Get Single Environment Variable

Returns a single environment variable by name. Response shape differs from the bulk endpoint (uses `name` + `value` instead of a flat map).

```
GET /api/v1/env/:name
```

**Parameters:**
- `name` (path, required) - Variable name. Must be path-encoded if it contains non-standard characters.

**Response (200):**
```json
{
  "data": {
    "name": "HOME",
    "value": "/home/alice"
  }
}
```

**Errors:**
- 403 - Variable is not in the allowlist
- 404 - Variable is in the allowlist but not set in the environment

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/env/HOME
```

#### Environment Variable Allowlist

By default, the following variables are exposed:

**Prefix matches** (any variable starting with):
`SLURM_`, `PBS_`, `SGE_`, `LSB_`, `LMOD_`, `MODULE`, `OOD_`

**Exact matches:**
`HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `LANG`, `LC_ALL`, `TERM`, `HOSTNAME`, `SCRATCH`, `WORK`, `TMPDIR`, `CLUSTER`, `MANPATH`

Sites can override the allowlist by setting the `OOD_API_ENV_ALLOWLIST` environment variable:

```
OOD_API_ENV_ALLOWLIST=SLURM_*,PBS_*,HOME,USER,SCRATCH,CUSTOM_VAR
```

Rules:
- Entries ending in `*` are prefix matches (the `*` is stripped)
- A bare `*` entry is ignored (would match everything)
- All other entries are exact matches
- Matching is case-sensitive
- Setting this **replaces** the defaults entirely
- Setting to empty (`OOD_API_ENV_ALLOWLIST=`) exposes nothing
- Whitespace around entries is stripped; duplicates are ignored
- Variable names containing commas are not supported

**Production sites should review the default allowlist** and set `OOD_API_ENV_ALLOWLIST` explicitly if any `OOD_*` variables contain sensitive values.

### Accounts

The Accounts API lists the scheduler accounts available to the authenticated user on a given cluster. This is useful for AI agents and scripts that need to discover valid `accounting_id` values before submitting jobs.

#### List Accounts

Returns all accounts available on the specified cluster.

```
GET /api/v1/accounts?cluster=:cluster_id
```

**Parameters:**
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": [
    {
      "name": "PAS1234",
      "qos": ["normal", "standby"],
      "cluster": "cluster1"
    }
  ]
}
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster not found
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/accounts?cluster=cluster1"
```

### Queues

The Queues API lists the queues (partitions) available on a given cluster. This is useful for AI agents and scripts that need to discover valid `queue_name` values before submitting jobs.

#### List Queues

Returns all queues on the specified cluster.

```
GET /api/v1/queues?cluster=:cluster_id
```

**Parameters:**
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": [
    {
      "name": "batch",
      "allow_qos": ["normal"],
      "deny_qos": [],
      "allow_accounts": null,
      "deny_accounts": [],
      "tres": {}
    }
  ]
}
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster not found
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/queues?cluster=cluster1"
```

### Cluster Info

The Cluster Info API returns resource utilization for a given cluster, including active and total counts for nodes, processors, and GPUs. This is useful for AI agents that need to reason about cluster load before submitting jobs.

#### Get Cluster Info

Returns resource utilization for the specified cluster.

```
GET /api/v1/cluster_info?cluster=:cluster_id
```

**Parameters:**
- `cluster` (query, required) - Cluster identifier

**Response:**
```json
{
  "data": {
    "active_nodes": 150,
    "total_nodes": 200,
    "active_processors": 4800,
    "total_processors": 6400,
    "active_gpus": 32,
    "total_gpus": 64
  }
}
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster not found
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/cluster_info?cluster=cluster1"
```

### Context

The Context API provides site-specific agent context from markdown files in the configured context directory. This is useful for AI agents that need to understand site-specific policies, guidelines, and conventions.

#### Get Context

Returns the concatenated contents of all `*.md` files in the context directory (`/etc/ood/config/agents.d/` by default).

```
GET /api/v1/context
```

**Response:**
```json
{
  "data": {
    "content": "# Site Policies\n\nAll jobs must specify an accounting ID.\n..."
  }
}
```

If the context directory does not exist or contains no markdown files, the response returns an empty context string.

**Configuration:**

| Variable | Default | Description |
|----------|---------|-------------|
| `OOD_API_CONTEXT_PATH` | `/etc/ood/config/agents.d` | Path to directory containing site-specific agent context files (*.md) |

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/context
```

## Error Handling

The API uses standard HTTP status codes:

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created (job submitted, directory created) |
| 400 | Bad Request (missing/invalid parameters) |
| 401 | Unauthorized (missing/invalid token) |
| 403 | Forbidden (permission denied, path not allowed) |
| 404 | Not Found (resource doesn't exist) |
| 413 | Payload Too Large (file exceeds size limit) |
| 422 | Unprocessable Entity (job submission/cancellation failed) |
| 500 | Internal Server Error |
| 503 | Service Unavailable (scheduler communication error) |
| 507 | Insufficient Storage (no space left on device) |

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
| `forbidden` | 403 | Permission denied or path not in allowed directories |
| `not_found` | 404 | Resource not found |
| `payload_too_large` | 413 | File exceeds maximum size limit |
| `unprocessable_entity` | 422 | Request understood but could not be processed |
| `service_unavailable` | 503 | Scheduler communication error |
| `insufficient_storage` | 507 | No space left on device |

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
    "cluster": "cluster1",
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
    f"{BASE_URL}/api/v1/jobs/{job_id}?cluster=cluster1",
    headers=headers
)
status = response.json()["data"]["status"]
print(f"Job {job_id} status: {status}")

# Cancel job
response = requests.delete(
    f"{BASE_URL}/api/v1/jobs/{job_id}?cluster=cluster1",
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
    "cluster": "cluster1",
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
    "$BASE_URL/api/v1/jobs/$JOB_ID?cluster=cluster1" | jq -r '.data.status')

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

## MCP Endpoint

The MCP server is built into the app at `/mcp`. See the [README](../README.md#3-mcp-endpoint) for client configuration examples.

## Future Enhancements

The following features are planned for future releases:

- **Token scopes** - Limit tokens to specific operations (read-only, jobs-only, etc.)
- **Token expiration** - Automatic token expiration after a configured period
- **Batch status checks** - Check multiple job statuses in a single request
- **Rate limiting** - Per-token rate limits to prevent abuse
