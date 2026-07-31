<!-- Site maintainers: this guide is based on ood-api's docs/user-guide.md template (v0.1.0). Note any local customizations here so future template updates don't overwrite them. -->

# OOD API — User Guide

A guide for **end users** of an Open OnDemand site that has deployed the OOD
API. It covers how to authenticate, call the REST API, and drive the MCP tools
from an LLM client.

This guide is written generically. Wherever you see a placeholder like
`<your-ood-host>` or `<your-idp>`, substitute the value for your site.

> **Admins — before you publish this guide for your users:**
>
> - Replace `<your-ood-host>` and `<your-idp>` throughout with your site's
>   values.
> - If your site doesn't enable application tokens, you can delete §1.2 and
>   the related row in the "Which method do I use?" table below — it won't
>   apply to your users.
> - Add a support contact where users can go if they get stuck: `<your
>   support contact, e.g. hpc-help@example.edu or your ticketing system>`.
> - See the [Installation guide](installation.md) and
>   [MCP authentication](mcp-auth.md) for configuring the auth methods
>   described below.

---

## Connect an AI assistant

If you want to manage your HPC work by chatting with an AI assistant (Claude
Desktop, Claude Code, Cursor, etc.) instead of using a terminal, this is all
you need.

**1. Get two things from your site administrator:** your OOD host address
(something like `ondemand.example.edu`), and whether your site has "OAuth
discovery" set up (your admin will know, it changes the command below).

**2. Connect your client.** If your site has OAuth discovery, point your
client at the address and it'll open a browser for you to log in:

```bash
claude mcp add ood-hpc --transport http https://<your-ood-host>/pun/sys/ood-api/mcp
```

If not, you'll need a JWT from your identity provider first. Ask your
administrator for your site's issuer URL and client ID, then use a tool like
`oidc-agent` to get a token (see
[§1.1](#11-bearer-jwt-from-your-identity-provider) below for the full
walkthrough). Once you have it:

```bash
claude mcp add ood-hpc --transport http \
  --header "Authorization: Bearer <your-jwt>" \
  https://<your-ood-host>/pun/sys/ood-api/mcp
```

**3. Start chatting.** Once connected, just ask in plain language:

> "What clusters can I use?"
>
> "Submit my run.sh script to cluster1 in the batch queue."
>
> "Is my job running yet?"

That's it, the assistant handles the rest. Writing a script instead, or want
the full detail on authentication? Keep reading below.

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
connecting MCP clients. Some sites additionally enable **application tokens**
(§1.2), either because their provider can't issue a verifiable JWT or because
they want a separate revocable credential per client. You'll know your site
uses them if your OOD Dashboard has an API Tokens page.

| You want to… | Use |
|---|---|
| Call the API or connect an MCP client (Claude Code, Claude Desktop, Cursor, …) | **Bearer JWT** (§1.1) — the usual method |
| Run unattended automation or CI | **Bearer JWT** (§1.1) |
| Use a site whose Dashboard has an API Tokens page | Whatever gets you past your site's login, **plus** an application token (§1.2) |
| Use a site that has no verifiable-JWT provider (e.g. Google OIDC) | Session cookie **plus** an application token (§1.2) |

An application token never travels alone — it accompanies whatever your site's
Apache accepts. If that is a JWT, the pairing is easy. If your site has no
verifiable-JWT provider, it is a **browser session cookie**, which you have to
copy out of DevTools and which expires with your OIDC session (8 hours by
default). That is tolerable for occasional interactive use and awkward for
anything unattended — see §1.2 before building a pipeline on it.

Quick test that you can reach the API at all:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://<your-ood-host>/pun/sys/ood-api/health
# -> {"status":"ok"}
```

`/health` skips the application-token check, but Apache still guards it like
every other path — without a valid session or JWT you get a redirect to your
identity provider, not a reply.

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
> [MCP authentication](mcp-auth.md).

### 1.2 Application tokens (if your site enabled them)

Some sites enable application tokens as well — either because their IdP
can't issue a verifiable JWT, or so you can hold a separate revocable credential
per client. You'll know this applies if your OOD Dashboard has a
**Settings → API Tokens** page (`/settings/api_tokens`). If it does, you can
issue a token yourself:

1. Open the OOD Dashboard in your browser and log in as usual.
2. Go to **Settings → API Tokens**.
3. Enter a descriptive name (e.g. "my laptop", "analysis script").
4. Click **Generate Token** and **copy it immediately** — it is shown only once.

An application token identifies you to the API, but it does **not** replace your
OOD login. With OOD's default Apache auth, a request carrying only a bearer token
is redirected to the login page — so from a terminal you send **both** your OOD
session cookie and the token.

This next part looks more technical than it is: your browser is already
holding that session cookie from when you logged in, you just need to copy it
out once. In Chrome or Firefox, open DevTools (F12), go to the
Application (Chrome) or Storage (Firefox) tab, find Cookies for your OOD site,
and copy the value of `mod_auth_openidc_session`. Then:

```bash
curl -H "Cookie: mod_auth_openidc_session=<your-session-cookie>" \
     -H "X-OOD-API-Token: <your-app-token>" \
     https://<your-ood-host>/pun/sys/ood-api/api/v1/clusters
```

The token itself doesn't expire on its own (it lives until you revoke it in the
Dashboard), but if you're pairing it with a browser session cookie, that cookie
lasts only as long as your OIDC session — log in again to refresh it.

An app token always accompanies something Apache accepts; it never replaces it.
MCP clients can use one if they can set two headers (`Authorization: Bearer
<your-jwt>` plus `X-OOD-API-Token`). For unattended work, a JWT alone (§1.1) is
simpler.

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
**[MCP authentication](mcp-auth.md)**.

### 3.2 Available tools

Nineteen tools, grouped by area. Required parameters are in **bold**.

If you're chatting with an AI client, you don't need to memorize any of this —
the client reads your request in plain language and fills in the right tool
and parameters itself. These tables matter most if you're calling tools
directly, writing scripts against the REST API, or are just curious what's
under the hood.

Four of them depend on your scheduler: `list_accounts`, `list_queues`,
`get_cluster_info`, and `list_historic_jobs` are fully supported on Slurm, and
on other schedulers commonly return "not supported by the … adapter". That is
your site's scheduler, not a broken install.

**Clusters**

| Tool | Parameters | Does |
|---|---|---|
| `list_clusters` | — | List clusters you can reach |
| `get_cluster` | **cluster_id** | Get cluster details |
| `list_accounts` | **cluster_id** | List accounts you can charge jobs to |
| `list_queues` | **cluster_id** | List queues and partitions |
| `get_cluster_info` | **cluster_id** | Get node, CPU, and GPU utilization |

**Jobs**

| Tool | Parameters | Does |
|---|---|---|
| `list_jobs` | **cluster_id** | List your active jobs |
| `get_job` | **cluster_id**, **job_id** | Get job details |
| `list_historic_jobs` | **cluster_id** | List completed jobs (accounting) |
| `submit_job` | **cluster_id**, **script_content**, plus optional parameters (see below) | Submit a batch job |
| `cancel_job` | **cluster_id**, **job_id** | Cancel a job |
| `hold_job` | **cluster_id**, **job_id** | Hold a queued job |
| `release_job` | **cluster_id**, **job_id** | Release a held job |

`submit_job`'s optional parameters: `workdir`, `job_name`, `queue_name`,
`accounting_id`, `wall_time` (seconds), `output_path`, `error_path`, `native`,
and dependencies (`after`, `afterok`, `afternotok`, `afterany`).

> MCP tools take **flat** parameters, as listed above — `script_content`,
> `job_name`, `wall_time`. The REST API nests the same values under `script`
> and `options` (`script.content`, `options.job_name`). If you are switching
> between the two, see [the REST reference](api.md#submit-job).

**Files** (paths must be absolute and within your allowed roots — normally your
home directory and `/tmp`)

A few paths inside your home are off limits even though you own them: `~/.ssh`,
your shell startup files (`.bashrc`, `.zshrc`, `.profile`, …),
`~/.config/ondemand`, and `~/.config/systemd/user`. Reads and writes both return
"not accessible through this API". You can still edit them normally in a shell
or the Files app — the restriction only stops an assistant from changing how you
log in.

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

## Getting help

Something here not matching what you're seeing, or stuck partway through?
Contact `<your site's support contact, e.g. hpc-help@example.edu or your
ticketing system>`.

## See also

- **[docs/api.md](api.md)** — complete REST API reference with examples
- **[docs/mcp-auth.md](mcp-auth.md)** — MCP client auth setup (static token and
  OAuth discovery)
- **[README](../README.md)** — what the app does, and what it can reach
- **[Installation](installation.md)** — for your administrator
