# Open OnDemand REST API

The Open OnDemand REST API provides programmatic access to HPC resources through OOD's scheduler abstraction layer. This API is designed for AI agents, automation scripts, and external tools that need to manage jobs, files, and the runtime environment without using the web interface.

## Table of Contents

- [Overview](#overview)
- [Authentication](#authentication)
- [API Reference](#api-reference) — [Health](#health) · [Clusters](#clusters) · [Jobs](#jobs) ·
  [Historic Jobs](#historic-jobs) · [Files](#files) ·
  [Environment Variables](#environment-variables) · [Accounts](#accounts) ·
  [Queues](#queues) · [Cluster Info](#cluster-info) · [Context](#context)
- [Error Handling](#error-handling)
- [Examples](#examples)
- [Application tokens](#application-tokens)
- [Security Considerations](#security-considerations)

## Overview

JSON over HTTP, rooted at:

```
https://<your-ood-host>/pun/sys/ood-api/api/v1
```

Scheduler operations go through OOD's `ood_core` adapters, so behaviour follows
whatever your site runs. Some endpoints are Slurm-only — see
[Compatibility](../README.md#compatibility--maintenance).

The same operations are also exposed as MCP tools at `/mcp`, backed by the same
handlers. Tool names and parameters are listed in the
[User Guide](user-guide.md#32-available-tools); note the MCP tools take flat
parameters where REST nests them.

## Authentication

Apache authenticates the request before it reaches ood-api, and OOD's per-user
nginx (PUN) runs the app as that user. Send an **`Authorization: Bearer <jwt>`**
header with a JWT from your identity provider:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters
```

That is all most clients need, and it is what every example below assumes. It
requires your site to have configured Apache for bearer validation — see the
[installation guide](installation.md#2-configure-authentication).

Sites may additionally require a per-client **application token** in an
`X-OOD-API-Token` header, alongside the JWT. If your OOD Dashboard has an
**API Tokens** page, yours is one of them — see
[Application tokens](#application-tokens) at the end of this document.

### Content-Type on writes

`POST`, `PUT`, and `PATCH` requests must send `Content-Type: application/json`,
or the API returns **415** — whether or not they carry a body. `DELETE` is
exempt. Every example below already does this.

This is a CSRF defense rather than a parsing requirement. With OOD's default
session-cookie authentication, a browser attaches your session to a
cross-origin form post automatically, so an attacker's page could otherwise
drive writes, deletes, and job submissions as you. An HTML form can only send
three content types, none of them JSON, and anything else triggers a preflight
that this API does not answer.

An `X-OOD-API-Token` header does not exempt a request. The filter cannot tell
a valid token from an invented one without running authentication, and where
application tokens are disabled there is no authentication to run — so
accepting the header's presence would let any value through.

`DELETE` is the one exemption, and it is scoped to the method rather than to
the body: no HTML form can issue a `DELETE`. Every other write needs
`Content-Type: application/json`, including a bodyless one such as
`POST ?touch=1`.


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

### Health

Confirms the app is running and serving requests. Used by the install and
upgrade checks, and suitable for a monitoring probe.

```
GET /health
```

**Response:**
```json
{
  "status": "ok"
}
```

Returns only that. No version, cluster list, or configuration is exposed.

**Authentication.** This is the one endpoint outside the application-token
check — it is not under `/api/v1/`, which is what that filter guards. It is
**not** unauthenticated: Apache sits in front of the whole portal, so a request
with no valid session or JWT gets a **302** to your IdP rather than a 200. A
monitoring probe therefore needs a credential like any other client, and a
probe that follows redirects will report success on the IdP's login page —
check for `200` with `{"status":"ok"}`, not merely a non-error.

**Errors:**
- 302 - No valid session or bearer token (redirect to the IdP, from Apache)

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
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters
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
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters/cluster1
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
      "native_state": "running",
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

**Job Status Values.** `status` is always one of these five, on every
scheduler, so a client can branch on it portably:

- `queued` - Job is waiting in queue
- `queued_held` - Job is held in queue
- `running` - Job is executing
- `suspended` - Job execution is suspended
- `completed` - Job has finished

Responses also carry **`native_state`**, your scheduler's own word for the
same job — `pending`, `cancelled`, `timeout`, `node_fail` and so on for Slurm.
It is `null` when the adapter exposes no native state.

Use `native_state` when you need an outcome `status` cannot express:
`cancelled`, `timeout`, and `failed` all arrive as `completed`, because
`ood_core` has no separate value for them. Treat it as scheduler-specific —
its values are not portable and are not enumerated here.

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs?cluster=cluster1"
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster not found
- 501 - Not supported by this cluster's scheduler adapter
- 503 - Scheduler communication error

#### Get Job

Returns details for a specific job.

> **Finished jobs age out.** A job stays queryable here for as long as your
> scheduler retains it — Slurm's `MinJobAge`, 300 seconds by default. After
> that it is gone from the active queue and this endpoint returns **404**; use
> [List Historic Jobs](#list-historic-jobs) for completed work. A polling loop
> should therefore treat 404 as "finished and aged out", not as an error, and
> should stop rather than retrying. A scheduler this endpoint cannot reach is
> reported as **503**, never as 404, so the two cases are safe to tell apart.

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
    "native_state": "running",
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
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs/12345?cluster=cluster1"
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster not found, or no such job (see note above)
- 501 - Not supported by this cluster's scheduler adapter
- 503 - Scheduler communication error

#### Submit Job

Submits a new job to the specified cluster. Unlike other job endpoints that use a query parameter, the cluster is specified in the JSON request body.

> The REST body **nests** the script and options (`script.content`,
> `options.job_name`, `options.wall_time`). The equivalent MCP tool takes the
> same values **flat** (`script_content`, `job_name`, `wall_time`) — see the
> [MCP tool reference](user-guide.md#32-available-tools). Sending the flat form to REST
> returns 400 `"script.content must be a string"`.

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
| `options.native` | array | No | Passed to the scheduler as command-line arguments, verbatim — see the note below |
| `options.after` | array | No | Job IDs that must start before this job is eligible |
| `options.afterok` | array | No | Job IDs that must complete successfully |
| `options.afternotok` | array | No | Job IDs that must fail |
| `options.afterany` | array | No | Job IDs that must complete (any exit status) |

**`options.native` is disabled by default.** It is raw scheduler argv, and
a caller can use it to override the paths this API validates — so a site that
wants it must set `OOD_API_ALLOW_NATIVE=true`. Without that, a request
carrying `native` is refused with 400.

When enabled: it must be a flat array of strings or numbers — any other shape
is refused with 400. Each element becomes a separate
command-line argument to the submit command — `["-N", "2"]` becomes `sbatch -N 2`.
Values are not interpreted by a shell, so a value containing `;` or `$(…)` is
passed through as one literal argument rather than executed. But any flag the
scheduler accepts is available through it, including ones that override the
other options in this request: a `native` of `["--partition=other"]` wins over
`options.queue_name`. It grants no privilege the user does not have — they could
run the submit command directly — but a site that expresses policy through
`queue_name` or `accounting_id` should not assume this endpoint enforces it.

Job scripts are likewise passed to the scheduler unchanged, so in-script
directives such as `#SBATCH` are honoured the same way they would be from a
login shell.

**Note:** Job dependency options (`after`, `afterok`, `afternotok`, `afterany`) are scheduler-dependent. Not all schedulers support all dependency types. Unsupported dependency types may be silently ignored or cause an error depending on the scheduler adapter.

**Response (201 Created):**
```json
{
  "data": {
    "job_id": "12346",
    "cluster": "cluster1",
    "job_name": "my-job",
    "status": "queued",
    "native_state": "pending",
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
  https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs
```

**Errors:**
- 400 - Missing `cluster`, `script.content` absent or not a string, `script`
  or `options` not an object, a non-integer `options.wall_time`, or
  `options.native` that is not a flat array of strings or numbers
- 403 - `script.workdir`, `options.output_path`, or `options.error_path` is
  outside the allowed roots or on the sensitive-path deny-list. The scheduler
  writes those paths as you, so they are validated like any other write
- 404 - Cluster not found
- 413 - The request body exceeds `OOD_API_MAX_FILE_WRITE`; a large job script
  hits the same limit as a file write
- 415 - `Content-Type` is not `application/json`
- 422 - The scheduler rejected the job (bad queue, account, or resource
  request); the message carries the scheduler's own text
- 503 - Scheduler unreachable
- 501 - Not supported by this cluster's scheduler adapter

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
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs/12345?cluster=cluster1"
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster or job not found
- 422 - The scheduler refused the cancellation
- 503 - Scheduler unreachable
- 501 - Not supported by this cluster's scheduler adapter

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
  -H "Content-Type: application/json" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs/12345/hold?cluster=cluster1"
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster or job not found
- 422 - The scheduler refused the hold (a running job cannot be held)
- 503 - Scheduler unreachable
- 501 - Not supported by this cluster's scheduler adapter

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
  -H "Content-Type: application/json" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs/12345/release?cluster=cluster1"
```

**Errors:**
- 400 - Missing `cluster` parameter
- 404 - Cluster or job not found
- 422 - The scheduler refused the release
- 503 - Scheduler unreachable
- 501 - Not supported by this cluster's scheduler adapter

### Historic Jobs

> **Slurm-mostly.** This is one of four capability areas — accounts, queues,
> cluster info, and job history — that depend on adapter features `ood_core`
> implements fully only for Slurm. On PBS Pro, LSF, Torque, or SGE these
> commonly return **501 `not_implemented`**. Handle that code; it means your
> site's scheduler, not a broken request.

The Historic Jobs API returns completed jobs from the scheduler's accounting database. Unlike the regular jobs endpoint which shows only active jobs, this endpoint returns jobs that have already finished.

**Operator note:** Some adapters may call accounting APIs that return more than one user's jobs. The API always **filters results to the authenticated user** by matching `job_owner` to the current user (same behavior for the MCP `list_historic_jobs` tool). If your scheduler reports ownership in an unexpected format, users may see fewer rows than in raw `sacct`/`qstat` output.

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
      "native_state": "completed",
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
- **501 - Not supported by this cluster's scheduler adapter** (see note above)
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/jobs/historic?cluster=cluster1"
```

### Files

The Files API provides access to files on the cluster. Access is restricted to the user's home directory and system temp directories.

**Denied paths.** Within those roots, a few locations are refused for both read
and write, and return `403 forbidden`:

| Path | Why |
|---|---|
| `~/.ssh` | SSH keys — write access would let a caller establish persistent login |
| `.bashrc`, `.zshrc`, `.profile`, and other shell init files | Executed on every login |
| `.bash_aliases` | Sourced by the stock Debian and Ubuntu `.bashrc` |
| `~/.config/ondemand` | This API's own token store |
| `~/.config/systemd/user` | User services survive the session |
| `~/.local/bin` | Precedes the system paths in `PATH` on current Fedora and Ubuntu, so a file here shadows a real command |
| `~/.gitconfig`, `~/.config/git` | `core.pager` and `core.sshCommand` run on the next git invocation |
| `~/.netrc` | Plaintext credentials, read by curl, ftp and git |
| `~/.config/autostart` | Launched on graphical login |
| `~/.forward` | `\|command` is executed by MTAs that honour it |
| `~/.pam_environment` | Read by PAM at session start where enabled |

Symlinks and hardlinks into these paths are refused too, and a recursive delete
of a parent directory is refused if a denied path lies beneath it. The user can
still edit these files by other means; the restriction exists so that an agent
acting on untrusted input cannot establish access that outlives the session.

**Limits (configurable via environment variables):**

| Limit | Default | Environment Variable |
|-------|---------|---------------------|
| Maximum file read | 10 MB | `OOD_API_MAX_FILE_READ` |
| Maximum file write | 50 MB | `OOD_API_MAX_FILE_WRITE` |

Values must be specified in bytes. Example: To allow 100 MB uploads, set `OOD_API_MAX_FILE_WRITE=104857600`.

These limits apply to **MCP as well as REST**: the `read_file` tool honors `max_size` capped by `OOD_API_MAX_FILE_READ`, and `write_file` rejects bodies over `OOD_API_MAX_FILE_WRITE`. MCP clients see a tool error with a text message (for example payload too large), not an HTTP `413` response.

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

**Errors:**
- 400 - Missing `path`, a non-scalar `path`, or a `path` containing a null byte
  or invalid UTF-8
- 403 - Path outside the allowed roots, or on the sensitive-path deny-list
- 404 - Path not found

#### Read File

Read the contents of a file.

```
GET /api/v1/files/content?path=:path[&max_size=:bytes]
```

**Parameters:**
- `path` (query, required) - Path to the file
- `max_size` (query, optional) - Maximum number of bytes to read. A value above the server-configured limit (default 10 MB) is silently clamped to it rather than rejected. Useful for reading only the beginning of large files.

Note that `max_size` changes how an oversized file is handled: **without** it, a
file larger than the server limit returns `400`; **with** it, you get `200` and
a truncated body. The response carries no indication that truncation occurred,
so compare the byte count you received against the `max_size` you asked for if
that distinction matters.

**Response:**
- Content-Type: `application/octet-stream`
- Body: Raw file contents

**Errors:**
- 400 - Cannot read directory, not a regular file (FIFO, device node), file
  too large, or a non-numeric or zero `max_size` (exceeds configured max, default 10 MB)
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
Content-Type: application/json
```

The body is written verbatim — it is not parsed as JSON. The header is a CSRF
control, not a parsing instruction; see
[Content-Type on writes](#content-type-on-writes).

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
- 415 - `Content-Type` is not `application/json`
- 413 - File too large (exceeds configured max, default 50 MB)
- 507 - The filesystem is full or the user is over quota

**Example:**
```bash
curl -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @local_file.txt \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~/remote_file.txt"
```

#### Create Directory or Empty File

Create a directory, or an empty file.

```
POST /api/v1/files?path=:path&type=directory   # directory
POST /api/v1/files?path=:path&touch=true       # empty file
```

**Parameters:**
- `path` (query, required) - Path to create
- `type` (query) - Pass `directory` to create a directory
- `touch` (query) - Pass `true`, `1`, `yes` or `on` to create an empty file
  (like `touch(1)`). Case and surrounding whitespace are ignored, so `TRUE`
  also works. Any other value, including `false` and `0`, is treated as not
  requested.
  Creating a file **with content** is `PUT`, not `POST`.

One of `type=directory` or `touch=true` is required; a `POST` with neither
returns 400 `"Use PUT to write file contents"`. `touch` on an existing file
updates its mtime and leaves the contents alone.

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
  -H "Content-Type: application/json" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/files?path=~/new_folder&type=directory"
```

**Errors:**
- 400 - Missing `path`, a null byte in `path`, a path already in use, or
  neither `type=directory` nor `touch` given (use `PUT` to write contents)
- 403 - Path outside the allowed roots, or on the sensitive-path deny-list
- 415 - `Content-Type` is not `application/json` (see [Authentication](#authentication))
- 507 - The filesystem is full or the user is over quota

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
- 400 - Directory not empty (when `recursive` is not `true`); `path` missing,
  repeated or sent as an array, or containing a null byte
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

**Errors:**
- 400 - `prefix` was repeated or sent as an array (`?prefix[]=x`)

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
- Setting this **replaces** the default allowlist entirely
- Setting to empty (`OOD_API_ENV_ALLOWLIST=`) exposes nothing
- Whitespace around entries is stripped; duplicates are ignored
- Variable names containing commas are not supported

**A credential-name deny pass runs first and cannot be overridden.** Names
containing `SECRET`, `TOKEN`, `PASSW`, `PASSPHRASE`, `CREDENTIAL`, `PRIVATE`,
`JWT`, `APIKEY`, `API_KEY`, `KEYRING`, `KEYFILE`, `KEYSTORE`, `BEARER`,
`OAUTH`, or `SIGNATURE` (case-insensitive) are never disclosed, even if you
list them explicitly. So are names ending in `_KEY`, `_PEM`, `_CERT`, `_PASS`,
`_PWD`, `_HMAC`, or `_REFRESH`.

Suffix handling differs by stem, and only `_KEY` is broadly covered: `MY_KEYS`
and `SLURM_KEY2` are refused while `SLURM_KEYWORD` is not, `X_CERTS` is refused
but `X_CERT2` is not, and the remaining stems match no suffix at all, so
`X_PASS2`, `X_PWDS`, `X_PEMS`, `X_HMACS` and `X_REFRESH2` are all allowed
through. Treat this pass as a backstop for an allowlist that is already
correct, not as the control — if a variable at your site holds a credential,
keep it out of the allowlist rather than relying on its name being caught.

This exists because the scheduler prefixes the default allowlist grants are
exactly where credentials appear — `SLURM_JWT` holds a bearer token for
`slurmrestd` and begins with the allowed `SLURM_` prefix, and these values
reach an LLM.

A listed-but-denied variable is absent from `GET /api/v1/env` and returns 403
from `GET /api/v1/env/:name`, with a message saying the name looks like a
credential. If your site genuinely needs to expose such a value, rename the
variable — there is no override.

**Production sites should review the default allowlist** and set `OOD_API_ENV_ALLOWLIST` explicitly if any `OOD_*` variables contain sensitive values.

### Accounts

> **Slurm-mostly.** This is one of four capability areas — accounts, queues,
> cluster info, and job history — that depend on adapter features `ood_core`
> implements fully only for Slurm. On PBS Pro, LSF, Torque, or SGE these
> return **501 `not_implemented`**. Handle that code; it means your site's
> scheduler, not a broken request. An empty list means you genuinely have
> none, which is why the two are distinguishable.

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
- **501 - Not supported by this cluster's scheduler adapter** (see note above)
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/accounts?cluster=cluster1"
```

### Queues

> **Slurm-mostly.** This is one of four capability areas — accounts, queues,
> cluster info, and job history — that depend on adapter features `ood_core`
> implements fully only for Slurm. On PBS Pro, LSF, Torque, or SGE these
> return **501 `not_implemented`**. Handle that code; it means your site's
> scheduler, not a broken request. An empty list means you genuinely have
> none, which is why the two are distinguishable.

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
- **501 - Not supported by this cluster's scheduler adapter** (see note above)
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/queues?cluster=cluster1"
```

### Cluster Info

> **Slurm-mostly.** This is one of four capability areas — accounts, queues,
> cluster info, and job history — that depend on adapter features `ood_core`
> implements fully only for Slurm. On PBS Pro, LSF, Torque, or SGE these
> commonly return **501 `not_implemented`**. Handle that code; it means your
> site's scheduler, not a broken request.

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
- **501 - Not supported by this cluster's scheduler adapter** (see note above)
- 503 - Scheduler communication error

**Example:**
```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://ondemand.example.com/pun/sys/ood-api/api/v1/cluster_info?cluster=cluster1"
```

### Context

The Context API provides site-specific agent context from markdown files in the configured context directory. This is useful for AI agents that need to understand site-specific policies, guidelines, and conventions.

#### Get Context

Returns the contents of all `*.md` files in the context directory
(`/etc/ood/config/agents.d/` by default), sorted by filename and joined with
blank lines.

The contents are not returned verbatim. Each fragment is preceded by an
`<!-- Source: <filename> -->` marker so a reader can tell which file said
what, and any such marker appearing *inside* a fragment is defanged, so one
file cannot impersonate another. Leading and trailing whitespace is stripped
from each fragment. A file larger than `OOD_API_MAX_CONTEXT_BYTES` (256 KB by
default) is replaced with a short note rather than served, and a file that
cannot be read — wrong permissions, a broken symlink — is skipped rather than
failing the whole request.

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
| `OOD_API_MAX_CONTEXT_BYTES` | `262144` (256 KB) | Per-file cap. A larger fragment is replaced with a note rather than served. |
| `OOD_API_MAX_CONTEXT_TOTAL_BYTES` | `1048576` (1 MB) | Cap across all fragments together. The per-file cap alone bounds nothing when there are many files. |

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
| 400 | Bad Request (missing/invalid parameters; also an oversized file **read** — see note) |
| 401 | Unauthorized (missing/invalid token) |
| 403 | Forbidden (permission denied, path not allowed) |
| 404 | Not Found (resource doesn't exist) |
| 413 | Payload Too Large (any request body exceeds the size limit, including a job script) |
| 415 | Unsupported Media Type (a write other than `DELETE` did not send `Content-Type: application/json`) |
| 422 | Unprocessable Entity (job submission/cancellation failed) |
| 500 | Internal Server Error |
| 501 | Not Implemented (the site's scheduler adapter does not support the operation) |
| 503 | Service Unavailable (scheduler communication error) |
| 507 | Insufficient Storage (no space left on device, disk quota exceeded, or file too large for the filesystem) |

> **413 applies to writes only.** `PUT /api/v1/files` returns 413
> `payload_too_large` when the request body exceeds `OOD_API_MAX_FILE_WRITE`.
> Reading a file larger than `OOD_API_MAX_FILE_READ` returns **400
> `bad_request`**, not 413. Pass `max_size` to read a prefix of a large file
> instead.

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
| `payload_too_large` | 413 | Write body exceeds the maximum size limit (writes only; an oversized read returns `bad_request`) |
| `unsupported_media_type` | 415 | A `POST`/`PUT`/`PATCH` did not send `Content-Type: application/json` (`DELETE` is exempt) |
| `unprocessable_entity` | 422 | Request understood but could not be processed |
| `not_implemented` | 501 | The site's scheduler adapter does not support this operation |
| `service_unavailable` | 503 | Scheduler communication error |
| `insufficient_storage` | 507 | The write could not be stored: no space left on device, disk quota exceeded, or file too large for the filesystem |

## Examples

### Python Example

```python
import requests

BASE_URL = "https://ondemand.example.com/pun/sys/ood-api"
TOKEN = "your-jwt-here"  # an IdP-issued JWT; see Authentication

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

if response.status_code != 201:
    raise SystemExit(f"Submit failed ({response.status_code}): {response.json()['message']}")

job = response.json()["data"]
print(f"Submitted job: {job['job_id']}")

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

BASE_URL="https://ondemand.example.com/pun/sys/ood-api"
TOKEN="your-jwt-here"      # an IdP-issued JWT; see Authentication

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

# Poll for completion.
#
# Two ways this loop ends: the job reports `completed`, or it ages out of the
# scheduler's active queue and the endpoint starts returning 404. Handle both,
# or the loop never exits. Keep the interval generous — there is no rate
# limiting, and a tight loop hammers the scheduler for every user on the host.
while true; do
  BODY=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/jobs/$JOB_ID?cluster=cluster1")
  CODE=$(printf '%s' "$BODY" | tail -n1)
  STATUS=$(printf '%s' "$BODY" | sed '$d' | jq -r '.data.status // empty')

  if [ "$CODE" = "404" ]; then
    echo "Job finished and aged out of the queue."
    break
  elif [ "$CODE" != "200" ]; then
    echo "Error querying job (HTTP $CODE)" >&2
    exit 1
  fi

  echo "Job status: $STATUS"
  [ "$STATUS" = "completed" ] && { echo "Job finished!"; break; }

  sleep 30
done

# Whether it succeeded is a separate question — the API reports scheduler
# state, not exit status. Read the job's output to find out:
#   curl -H "Authorization: Bearer $TOKEN" \
#     "$BASE_URL/api/v1/files/content?path=$OUTPUT_PATH"
```

## Application tokens

For sites using Google OIDC or other IdPs that don't publish a JWKS endpoint with verifiable access tokens, ood-api can manage its own tokens. Enable this mode by setting an environment variable on the PUN (e.g. via `passenger_env_var` in your `pun.conf.erb`):

```
OOD_API_APP_TOKENS=true
```

With this set, **every request to `/api/v1/*` and to `/mcp`** must carry a valid token issued by the Dashboard plugin, in the `X-OOD-API-Token` header:

```
X-OOD-API-Token: <token>
```

Without the flag, this header is ignored and the JWT flow in [Authentication](#authentication) applies.

**The token goes in `X-OOD-API-Token`, not `Authorization`.** Apache owns the
`Authorization` header: when configured for bearer validation
(`AuthType auth-openidc`) it consumes that header for the IdP's
JWT, leaving nowhere for a second credential. Giving app tokens their own
header lets a client satisfy both layers on one request, and is what allows MCP
clients to use app tokens at all.

**Application tokens do not replace Apache's auth**; they are a second
factor on top of it. A request must still get past Apache, either with an OIDC
**session cookie** (OOD's default `AuthType openid-connect`) or with a bearer
JWT (`AuthType auth-openidc`). A request carrying only `X-OOD-API-Token` and
nothing Apache accepts is rejected — or 302-redirected to your IdP — before it
ever reaches ood-api.

### Generating a Token

1. Log in to Open OnDemand in a browser
2. Navigate to **Settings > API Tokens** (`/settings/api_tokens`)
3. Enter a descriptive name for your token (e.g., "My Script", "CI Pipeline")
4. Click **Generate Token**
5. **Copy the token immediately** - it will only be shown once

### Using a Token

From inside the browser session (Dashboard JS, browser extension, fetch from a bookmarklet), send the token in `X-OOD-API-Token` — the session cookie rides along automatically:

```js
fetch('/pun/sys/ood-api/api/v1/clusters', {
  headers: { 'X-OOD-API-Token': 'YOUR_TOKEN_HERE' }
})
```

### Using a Token from a Terminal or Script

From a terminal or CI job, pass **both** something Apache accepts and the app token. With OOD's default session-cookie auth, grab the OIDC session cookie from your browser once (DevTools → Application → Cookies → `mod_auth_openidc_session`), then:

```bash
curl -H "Cookie: mod_auth_openidc_session=YOUR_SESSION_COOKIE" \
     -H "X-OOD-API-Token: YOUR_TOKEN_HERE" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters
```

At a site running `AuthType auth-openidc`, use a JWT for Apache instead of the cookie — the two headers do not conflict:

```bash
curl -H "Authorization: Bearer YOUR_JWT" \
     -H "X-OOD-API-Token: YOUR_TOKEN_HERE" \
  https://ondemand.example.com/pun/sys/ood-api/api/v1/clusters
```

### Using a Token with MCP

MCP clients send the same header. With Claude Code:

```bash
claude mcp add ood-hpc --transport http \
  --header "Authorization: Bearer YOUR_JWT" \
  --header "X-OOD-API-Token: YOUR_TOKEN_HERE" \
  https://ondemand.example.com/pun/sys/ood-api/mcp
```

A client that cannot set a custom header cannot use app tokens; such sites should rely on Apache-level auth alone.

### Session lifetime

When Apache is gating with a **session cookie**, that cookie is valid for the configured OIDC session lifetime — by default 8 hours inactivity / 8 hours max (see `OIDCSessionInactivityTimeout` and `OIDCSessionMaxDuration` in `ood_portal.yml`). Refresh it by logging in again when it expires. The app token itself does not expire; it is valid until revoked.

For unattended CI or long-running jobs, prefer a JWT alone, which does not depend on a browser session.

### Token Storage

Tokens are stored in the user's home directory at `~/.config/ondemand/tokens.json` with `600` permissions (readable only by the owner). Each token includes:

- Unique ID
- User-defined name
- Creation timestamp
- Last used timestamp

### Revoking Tokens

Tokens can be revoked through the web interface at **Settings > API Tokens**. Revoked tokens are immediately invalidated.

## Security Considerations

Every request runs as the authenticated user inside their PUN, so the API grants
no privilege the user does not already have. What it *does* constrain — the path
allowlist, the denied paths inside `$HOME`, size limits, the environment
allowlist, audit logging — and what it deliberately does not — no rate limiting,
no read-only mode, no per-user enablement — is documented in the README's
**[SECURITY.md](../SECURITY.md)**. Read that before
deploying.

API-specific details not covered there:

- Application tokens are 64-character hex strings (256 bits of entropy), stored
  at `~/.config/ondemand/tokens.json` with mode `600`, and compared in
  constant time.
- A token carries no scope: it authenticates the user, and the request then has
  everything that user has. Revoke through **Settings > API Tokens**.
- Use HTTPS. Bearer credentials in a URL query string are never accepted; they
  belong in headers.
