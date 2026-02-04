#!/usr/bin/env python3
"""
MCP Server for Open OnDemand API

This server provides MCP (Model Context Protocol) tools for interacting with
HPC clusters through the Open OnDemand REST API.

Tools provided:
- list_clusters: List available HPC clusters
- get_cluster: Get details about a specific cluster
- list_jobs: List jobs on a cluster
- get_job: Get details about a specific job
- submit_job: Submit a new batch job
- cancel_job: Cancel a running/queued job

Configuration (environment variables):
- OOD_API_URL: Base URL of OOD instance (default: http://localhost:9292)
- OOD_API_TOKEN: API bearer token (required)

See README.md for full documentation.
"""

import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
from typing import Any

from mcp.server.fastmcp import FastMCP

# Configuration
OOD_API_URL = os.environ.get("OOD_API_URL", "http://localhost:9292")
OOD_API_TOKEN = os.environ.get("OOD_API_TOKEN", "")

if not OOD_API_TOKEN:
    print("Warning: OOD_API_TOKEN environment variable is not set. API requests will fail.", file=sys.stderr)

# Initialize FastMCP server
mcp = FastMCP(
    "ood-hpc",
    instructions="Open OnDemand HPC cluster management tools. Use these tools to list clusters, view and submit jobs, and manage HPC workloads."
)


def api_request(method: str, path: str, data: dict | None = None) -> dict:
    """Make a request to the OOD API."""
    url = f"{OOD_API_URL}{path}"
    headers = {
        "Authorization": f"Bearer {OOD_API_TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        try:
            return json.loads(error_body)
        except json.JSONDecodeError:
            return {"error": e.code, "message": error_body}
    except urllib.error.URLError as e:
        return {"error": "connection_error", "message": str(e.reason)}


@mcp.tool()
def list_clusters() -> str:
    """
    List all available HPC clusters.

    Returns cluster IDs, names, scheduler types, and login hosts.
    """
    result = api_request("GET", "/api/v1/clusters")
    if "data" in result:
        clusters = result["data"]
        if not clusters:
            return "No clusters available."
        lines = ["Available HPC Clusters:", ""]
        for c in clusters:
            lines.append(f"- {c['id']}: {c.get('title', c['id'])}")
            lines.append(f"  Scheduler: {c.get('adapter', 'unknown')}")
            if c.get("login_host"):
                lines.append(f"  Login host: {c['login_host']}")
            lines.append("")
        return "\n".join(lines)
    return f"Error: {result.get('message', 'Unknown error')}"


@mcp.tool()
def get_cluster(cluster_id: str) -> str:
    """
    Get details about a specific HPC cluster.

    Args:
        cluster_id: The cluster ID (e.g., 'owens', 'pitzer')
    """
    encoded_id = urllib.parse.quote(cluster_id, safe='')
    result = api_request("GET", f"/api/v1/clusters/{encoded_id}")
    if "data" in result:
        c = result["data"]
        return f"""Cluster: {c['id']}
Title: {c.get('title', c['id'])}
Scheduler: {c.get('adapter', 'unknown')}
Login Host: {c.get('login_host', 'N/A')}"""
    return f"Error: {result.get('message', 'Cluster not found')}"


@mcp.tool()
def list_jobs(cluster_id: str) -> str:
    """
    List all jobs for the current user on a specific cluster.

    Args:
        cluster_id: The cluster ID to list jobs from
    """
    encoded_cluster = urllib.parse.quote(cluster_id, safe='')
    result = api_request("GET", f"/api/v1/jobs?cluster={encoded_cluster}")
    if "data" in result:
        jobs = result["data"]
        if not jobs:
            return f"No jobs found on cluster '{cluster_id}'."
        lines = [f"Jobs on {cluster_id}:", ""]
        for j in jobs:
            lines.append(f"Job ID: {j['job_id']}")
            lines.append(f"  Name: {j.get('job_name', 'N/A')}")
            lines.append(f"  Status: {j.get('status', 'unknown')}")
            lines.append(f"  Queue: {j.get('queue_name', 'N/A')}")
            lines.append("")
        return "\n".join(lines)
    return f"Error: {result.get('message', 'Failed to list jobs')}"


@mcp.tool()
def get_job(cluster_id: str, job_id: str) -> str:
    """
    Get details about a specific job.

    Args:
        cluster_id: The cluster ID where the job is running
        job_id: The job ID
    """
    encoded_job = urllib.parse.quote(job_id, safe='')
    encoded_cluster = urllib.parse.quote(cluster_id, safe='')
    result = api_request("GET", f"/api/v1/jobs/{encoded_job}?cluster={encoded_cluster}")
    if "data" in result:
        j = result["data"]
        return f"""Job Details:
Job ID: {j['job_id']}
Cluster: {j.get('cluster', cluster_id)}
Name: {j.get('job_name', 'N/A')}
Status: {j.get('status', 'unknown')}
Owner: {j.get('job_owner', 'N/A')}
Queue: {j.get('queue_name', 'N/A')}
Account: {j.get('accounting_id', 'N/A')}
Submitted: {j.get('submitted_at', 'N/A')}
Started: {j.get('started_at', 'N/A')}
Wall Time: {j.get('wallclock_time', 'N/A')} / {j.get('wallclock_limit', 'N/A')} seconds"""
    return f"Error: {result.get('message', 'Job not found')}"


@mcp.tool()
def submit_job(
    cluster_id: str,
    script_content: str,
    job_name: str | None = None,
    queue_name: str | None = None,
    wall_time: int | None = None,
    workdir: str | None = None,
    accounting_id: str | None = None,
) -> str:
    """
    Submit a new job to an HPC cluster.

    Args:
        cluster_id: The cluster ID to submit the job to
        script_content: The bash script content (should start with #!/bin/bash)
        job_name: Name for the job (optional)
        queue_name: Queue/partition to submit to (optional)
        wall_time: Wall time limit in seconds (optional)
        workdir: Working directory for the job (optional)
        accounting_id: Account/project ID for billing (optional)
    """
    payload: dict[str, Any] = {
        "cluster": cluster_id,
        "script": {"content": script_content},
        "options": {},
    }

    if workdir:
        payload["script"]["workdir"] = workdir
    if job_name:
        payload["options"]["job_name"] = job_name
    if queue_name:
        payload["options"]["queue_name"] = queue_name
    if wall_time:
        payload["options"]["wall_time"] = wall_time
    if accounting_id:
        payload["options"]["accounting_id"] = accounting_id

    result = api_request("POST", "/api/v1/jobs", payload)
    if "data" in result:
        j = result["data"]
        return f"""Job submitted successfully!
Job ID: {j['job_id']}
Cluster: {j.get('cluster', cluster_id)}
Status: {j.get('status', 'submitted')}"""
    return f"Error submitting job: {result.get('message', 'Unknown error')}"


@mcp.tool()
def cancel_job(cluster_id: str, job_id: str) -> str:
    """
    Cancel a running or queued job.

    Args:
        cluster_id: The cluster ID where the job is running
        job_id: The job ID to cancel
    """
    encoded_job = urllib.parse.quote(job_id, safe='')
    encoded_cluster = urllib.parse.quote(cluster_id, safe='')
    result = api_request("DELETE", f"/api/v1/jobs/{encoded_job}?cluster={encoded_cluster}")
    if "data" in result:
        return f"Job {job_id} has been cancelled."
    return f"Error cancelling job: {result.get('message', 'Unknown error')}"


if __name__ == "__main__":
    mcp.run()
