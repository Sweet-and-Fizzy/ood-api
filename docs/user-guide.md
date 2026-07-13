# OOD API — User Guide

A guide for **end users** of an Open OnDemand site that has deployed the OOD
API. It covers how to authenticate, call the REST API, and drive the MCP tools
from an LLM client.

This guide is written generically. Wherever you see a placeholder like
`<your-ood-host>` or `<your-idp>`, substitute the value for your site — your
site administrator can provide these, and sites are encouraged to copy this
guide and fill in their specifics for their own users.

> **Admins:** this is the user-facing companion to the setup docs. See the
> [README](../README.md) for installation and [MCP authentication](mcp-oauth.md)
> for configuring the auth methods below. Point your users here.

---

## 1. Authenticating

Every request to the API runs as *you* — the OOD per-user process (PUN) executes
the app as your account. Before you can call anything, your request has to carry
proof of who you are. How you provide that depends on which method your site
enabled. There are two, and **your site may support one or both** — if you are
not sure which applies, ask your administrator.

### Which method do I use?

Most sites authenticate with an OpenID Connect identity provider and use
**bearer JWTs** (§1.1) — that is the normal path for calling the API and for
connecting MCP clients. **Application tokens** (§1.2) are a fallback that some
sites enable when their provider can't issue a verifiable JWT; you'll know your
site uses them if your OOD Dashboard has an API Tokens page.

| You want to… | Use |
|---|---|
| Call the API or connect an MCP client (Claude Code, Claude Desktop, Cursor, …) | **Bearer JWT** (§1.1) — the usual method |
| Run unattended automation or CI | **Bearer JWT** (§1.1) |
| Use a site that has no verifiable-JWT provider (e.g. Google OIDC) | **Application token** (§1.2), if your Dashboard offers one |

Quick test that you can reach the API at all (the health endpoint needs no auth):

```bash
curl https://<your-ood-host>/pun/sys/ood-api/health
# -> {"status":"ok"}
```

### 1.1 Bearer JWT (from your identity provider)

This is the usual method. The API does **not** issue JWTs. A JWT comes from the
OpenID Connect identity provider (IdP) that your OOD site authenticates against —
the API only validates it.

Getting a token from an OIDC provider by hand is fiddly and provider-specific, so
rather than crafting OAuth requests yourself, use a maintained CLI token tool:

- **[oidc-agent](https://indigo-dc.github.io/oidc-agent/)** — the common choice in
  research computing. It manages OIDC tokens like `ssh-agent` manages keys, works
  with arbitrary providers, and supports the browser-based device flow
  (`oidc-gen --flow=device`) for machines without a local browser. Packaged for
  apt and Homebrew.
- **[oauth2c](https://github.com/cloudentity/oauth2c)** or
  **[oidc-cli](https://github.com/jentz/oidc-cli)** — lighter alternatives that
  fetch a token via any grant type.

You configure the tool once with values your site provides — the **issuer URL**
and a **client ID** (and secret, if your site's client needs one). **Ask your
administrator for these**, and whether they've registered a client for the API;
some sites publish a ready-made helper or a wrapper script. The tool then prints a
token you pass as a bearer header:

```bash
curl -H "Authorization: Bearer <your-jwt>" \
     https://<your-ood-host>/pun/sys/ood-api/api/v1/clusters
```

JWTs expire (typically in minutes to an hour), so a long-running script will start
getting `401` responses and must fetch a fresh token; `oidc-agent` will refresh
one for you on demand. MCP clients using OAuth discovery (§3.1) handle this
refresh automatically.

If your site's IdP can't issue a verifiable JWT (e.g. Google OIDC), the JWT path
isn't available — use application tokens (§1.2) instead.

> MCP clients using OAuth discovery can skip all of this — the client performs the
> login flow for you in a browser. See §3.1 and
> [MCP authentication](mcp-oauth.md).

### 1.2 Application tokens (fallback, if your site enabled them)

Some sites — typically those whose IdP can't issue a verifiable JWT — enable
application-level tokens instead. You'll know this applies if your OOD Dashboard
has a **Settings → API Tokens** page (`/settings/api_tokens`). If it does, you can
issue a token yourself:

1. Open the OOD Dashboard in your browser and log in as usual.
2. Go to **Settings → API Tokens**.
3. Enter a descriptive name (e.g. "my laptop", "analysis script").
4. Click **Generate Token** and **copy it immediately** — it is shown only once.

An application token identifies you to the API, but it does **not** replace your
OOD login. With OOD's default Apache auth, a request carrying only a bearer token
is redirected to the login page — so from a terminal you send **both** your OOD
session cookie and the token. Grab the session cookie from your browser once
(DevTools → Application → Cookies → `mod_auth_openidc_session`), then:

```bash
curl -H "Cookie: mod_auth_openidc_session=<your-session-cookie>" \
     -H "Authorization: Bearer <your-app-token>" \
     https://<your-ood-host>/pun/sys/ood-api/api/v1/clusters
```

The token itself doesn't expire on its own (it lives until you revoke it in the
Dashboard), but the session cookie you must pair with it lasts only as long as
your OIDC session — log in again to refresh it. MCP clients can't use application
tokens (they can't carry your browser cookie past Apache), so for MCP or
unattended work use a JWT (§1.1).

---

## 2. Using the REST API

Base URL: `https://<your-ood-host>/pun/sys/ood-api/api/v1`

Every endpoint returns JSON. A minimal example — list the clusters you can reach:

```bash
curl -H "Authorization: Bearer <your-jwt>" \
     https://<your-ood-host>/pun/sys/ood-api/api/v1/clusters
```

The full REST reference — every endpoint, request body, response shape, error
code, plus runnable Python and shell examples — is in
**[docs/api.md](api.md)**. Start there for anything beyond the basics.

---

## 3. Using the MCP tools

The API also exposes a Model Context Protocol (MCP) server, so an LLM client can
manage your HPC work conversationally. The client discovers the tools and their
parameters automatically once connected — you drive it with plain requests like
"list my running jobs on cluster1."

### 3.1 Connecting a client

MCP endpoint: `https://<your-ood-host>/pun/sys/ood-api/mcp`

The simplest connection (Claude Code, static token):

```bash
claude mcp add ood-hpc --transport http \
  --header "Authorization: Bearer <your-jwt>" \
  https://<your-ood-host>/pun/sys/ood-api/mcp
```

If your site set up OAuth discovery, you can omit the header and the client
handles login in a browser. Full client setup for Claude Code, Claude Desktop,
and Cursor — including auto-refreshing tokens — is in
**[MCP authentication](mcp-oauth.md)**.

### 3.2 Available tools

Nineteen tools, grouped by area. Required parameters are in **bold**.

**Clusters**

| Tool | Parameters | Does |
|---|---|---|
| `list_clusters` | — | List clusters you can reach |
| `get_cluster` | **cluster_id** | Cluster details |
| `list_accounts` | **cluster_id** | Accounts you can charge jobs to |
| `list_queues` | **cluster_id** | Queues/partitions |
| `get_cluster_info` | **cluster_id** | Node/CPU/GPU utilization |

**Jobs**

| Tool | Parameters | Does |
|---|---|---|
| `list_jobs` | **cluster_id** | Your active jobs |
| `get_job` | **cluster_id**, **job_id** | Job details |
| `list_historic_jobs` | **cluster_id** | Completed jobs (accounting) |
| `submit_job` | **cluster_id**, **script_content**, and optional `workdir`, `job_name`, `queue_name`, `accounting_id`, `wall_time` (seconds), `output_path`, `error_path`, `native`, and dependencies (`after`, `afterok`, `afternotok`, `afterany`) | Submit a batch job |
| `cancel_job` | **cluster_id**, **job_id** | Cancel a job |
| `hold_job` | **cluster_id**, **job_id** | Hold a queued job |
| `release_job` | **cluster_id**, **job_id** | Release a held job |

**Files** (paths must be absolute and within your allowed roots)

| Tool | Parameters | Does |
|---|---|---|
| `list_files` | **path** | List a directory |
| `read_file` | **path**, optional `max_size` | Read a file |
| `write_file` | **path**, **content**, optional `append` | Write or append |
| `create_directory` | **path** | Make a directory |
| `delete_file` | **path**, optional `recursive` | Delete a file or directory |

**Environment**

| Tool | Parameters | Does |
|---|---|---|
| `list_env` | optional `prefix` | List allowed environment variables |
| `get_env` | **name** | Get one variable |

There is also an `ood://context` resource carrying your site's policies and
guidance; a well-behaved client reads it before acting.

### 3.3 A worked flow

Once connected, you drive the tools in natural language. A typical
submit-and-monitor session:

> **You:** What clusters can I use?
> *(client calls `list_clusters`)*
>
> **You:** On cluster1, what accounts and queues do I have?
> *(client calls `list_accounts` and `list_queues` with cluster_id "cluster1")*
>
> **You:** Submit a job to cluster1 in the "batch" queue on account PROJ1 that
> runs my `~/run.sh`, name it "analysis".
> *(client calls `submit_job` with cluster_id, queue_name, accounting_id,
> job_name, and script_content — reading your script if needed)*
>
> **You:** Is it running yet?
> *(client calls `list_jobs` or `get_job` to report status)*

The discover-first pattern — check accounts and queues before submitting — avoids
the most common submission errors, since valid values differ per site.

---

## See also

- **[docs/api.md](api.md)** — complete REST API reference with examples
- **[docs/mcp-oauth.md](mcp-oauth.md)** — MCP client auth setup (static token and
  OAuth discovery)
- **[README](../README.md)** — overview, installation, and configuration
