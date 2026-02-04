#!/usr/bin/env python3
"""
Tests for the OOD MCP Server

Run with: pytest test_server.py -v
"""

import json
import pytest
from unittest.mock import patch, MagicMock
import urllib.error

# Set test defaults before importing server
import os
os.environ.setdefault("OOD_API_URL", "http://localhost:9292")
os.environ.setdefault("OOD_API_TOKEN", "test-token")

from server import (
    api_request,
    list_clusters,
    get_cluster,
    list_jobs,
    get_job,
    submit_job,
    cancel_job,
)


def mock_urlopen_response(json_data):
    """Create a mock urllib response."""
    response = MagicMock()
    response.read.return_value = json.dumps(json_data).encode("utf-8")
    response.__enter__ = MagicMock(return_value=response)
    response.__exit__ = MagicMock(return_value=False)
    return response


class TestApiRequest:
    """Tests for the low-level API request function."""

    @patch("server.urllib.request.urlopen")
    def test_successful_get_request(self, mock_urlopen):
        """Should return JSON data for successful requests."""
        mock_urlopen.return_value = mock_urlopen_response({"status": "ok"})

        result = api_request("GET", "/health")

        assert result == {"status": "ok"}
        mock_urlopen.assert_called_once()

    @patch("server.urllib.request.urlopen")
    def test_unauthorized_response(self, mock_urlopen):
        """Should return error for 401 responses."""
        error = urllib.error.HTTPError(
            url="http://test",
            code=401,
            msg="Unauthorized",
            hdrs={},
            fp=MagicMock(read=lambda: b'{"error": "unauthorized", "message": "Invalid token"}')
        )
        mock_urlopen.side_effect = error

        result = api_request("GET", "/api/v1/clusters")

        assert result.get("error") == "unauthorized"

    @patch("server.urllib.request.urlopen")
    def test_connection_error_handled(self, mock_urlopen):
        """Connection errors should be handled gracefully."""
        mock_urlopen.side_effect = urllib.error.URLError("Connection refused")

        result = api_request("GET", "/health")

        assert result["error"] == "connection_error"
        assert "Connection refused" in result["message"]


class TestListClusters:
    """Tests for list_clusters tool."""

    @patch("server.api_request")
    def test_formats_cluster_list(self, mock_api):
        """Should format cluster data as readable text."""
        mock_api.return_value = {
            "data": [
                {"id": "cluster1", "title": "Cluster One", "adapter": "slurm", "login_host": "login1.example.com"},
                {"id": "cluster2", "title": "Cluster Two", "adapter": "pbs", "login_host": "login2.example.com"},
            ]
        }

        result = list_clusters()

        assert "Available HPC Clusters:" in result
        assert "cluster1" in result
        assert "Cluster One" in result
        assert "slurm" in result
        assert "cluster2" in result

    @patch("server.api_request")
    def test_handles_empty_list(self, mock_api):
        """Should handle no clusters gracefully."""
        mock_api.return_value = {"data": []}

        result = list_clusters()

        assert "No clusters" in result

    @patch("server.api_request")
    def test_handles_api_error(self, mock_api):
        """Should return error message for API failures."""
        mock_api.return_value = {"error": "unauthorized", "message": "Invalid token"}

        result = list_clusters()

        assert "Error:" in result


class TestGetCluster:
    """Tests for get_cluster tool."""

    @patch("server.api_request")
    def test_formats_cluster_details(self, mock_api):
        """Should format single cluster details."""
        mock_api.return_value = {
            "data": {
                "id": "owens",
                "title": "Owens Cluster",
                "adapter": "slurm",
                "login_host": "owens.osc.edu"
            }
        }

        result = get_cluster("owens")

        assert "Cluster: owens" in result
        assert "Owens Cluster" in result
        assert "slurm" in result
        assert "owens.osc.edu" in result

    @patch("server.api_request")
    def test_handles_not_found(self, mock_api):
        """Should return error for nonexistent cluster."""
        mock_api.return_value = {"error": "not_found", "message": "Cluster not found"}

        result = get_cluster("nonexistent")

        assert "Error:" in result

    @patch("server.api_request")
    def test_empty_cluster_id_returns_error(self, mock_api):
        """Should return error for empty cluster ID."""
        mock_api.return_value = {"error": "bad_request", "message": "cluster parameter is required"}

        result = get_cluster("")

        assert "Error:" in result


class TestListJobs:
    """Tests for list_jobs tool."""

    @patch("server.api_request")
    def test_formats_job_list(self, mock_api):
        """Should format job list as readable text."""
        mock_api.return_value = {
            "data": [
                {"job_id": "123", "job_name": "test-job", "status": "running", "queue_name": "batch"},
                {"job_id": "456", "job_name": "another", "status": "queued", "queue_name": "debug"},
            ]
        }

        result = list_jobs("owens")

        assert "Jobs on owens:" in result
        assert "123" in result
        assert "test-job" in result
        assert "running" in result

    @patch("server.api_request")
    def test_handles_no_jobs(self, mock_api):
        """Should show message when no jobs found."""
        mock_api.return_value = {"data": []}

        result = list_jobs("owens")

        assert "No jobs found" in result

    @patch("server.api_request")
    def test_empty_cluster_id_returns_error(self, mock_api):
        """Should return error for empty cluster ID."""
        mock_api.return_value = {"error": "bad_request", "message": "cluster parameter is required"}

        result = list_jobs("")

        assert "Error:" in result

    @patch("server.api_request")
    def test_handles_api_error(self, mock_api):
        """Should return error for API failures."""
        mock_api.return_value = {"error": "not_found", "message": "Cluster not found"}

        result = list_jobs("nonexistent")

        assert "Error:" in result


class TestGetJob:
    """Tests for get_job tool."""

    @patch("server.api_request")
    def test_formats_job_details(self, mock_api):
        """Should format job details."""
        mock_api.return_value = {
            "data": {
                "job_id": "12345",
                "job_name": "my-job",
                "status": "running",
                "queue_name": "batch",
                "job_owner": "user1"
            }
        }

        result = get_job("owens", "12345")

        assert "12345" in result
        assert "my-job" in result
        assert "running" in result

    @patch("server.api_request")
    def test_handles_not_found(self, mock_api):
        """Should return error for nonexistent job."""
        mock_api.return_value = {"error": "not_found", "message": "Job not found"}

        result = get_job("owens", "99999")

        assert "Error:" in result

    @patch("server.api_request")
    def test_empty_cluster_id_returns_error(self, mock_api):
        """Should return error for empty cluster ID."""
        mock_api.return_value = {"error": "bad_request", "message": "cluster parameter is required"}

        result = get_job("", "12345")

        assert "Error:" in result

    @patch("server.api_request")
    def test_empty_job_id_returns_error(self, mock_api):
        """Should return error for empty job ID."""
        mock_api.return_value = {"error": "not_found", "message": "Job not found"}

        result = get_job("owens", "")

        assert "Error:" in result


class TestSubmitJob:
    """Tests for submit_job tool."""

    @patch("server.api_request")
    def test_submits_job_successfully(self, mock_api):
        """Should format successful submission result."""
        mock_api.return_value = {
            "data": {
                "job_id": "12346",
                "status": "queued",
                "job_name": "api-job"
            }
        }

        result = submit_job("owens", "#!/bin/bash\necho hello", job_name="api-job")

        assert "Job submitted successfully!" in result
        assert "12346" in result
        mock_api.assert_called_once()

    @patch("server.api_request")
    def test_includes_job_options(self, mock_api):
        """Should pass job options to API."""
        mock_api.return_value = {"data": {"job_id": "123", "status": "queued"}}

        submit_job("owens", "#!/bin/bash\necho test", job_name="test", wall_time=3600, queue_name="debug")

        call_args = mock_api.call_args[0]
        body = call_args[2]
        assert body["options"]["job_name"] == "test"
        assert body["options"]["wall_time"] == 3600
        assert body["options"]["queue_name"] == "debug"

    @patch("server.api_request")
    def test_empty_cluster_id_returns_error(self, mock_api):
        """Should return error for empty cluster ID."""
        mock_api.return_value = {"error": "bad_request", "message": "cluster parameter is required"}

        result = submit_job("", "#!/bin/bash\necho test")

        assert "Error" in result

    @patch("server.api_request")
    def test_empty_script_returns_error(self, mock_api):
        """Should return error for empty script content."""
        mock_api.return_value = {"error": "bad_request", "message": "script.content is required"}

        result = submit_job("owens", "")

        assert "Error" in result

    @patch("server.api_request")
    def test_handles_submission_error(self, mock_api):
        """Should return error for submission failures."""
        mock_api.return_value = {"error": "unprocessable_entity", "message": "Invalid script"}

        result = submit_job("owens", "bad script")

        assert "Error" in result


class TestCancelJob:
    """Tests for cancel_job tool."""

    @patch("server.api_request")
    def test_cancels_job_successfully(self, mock_api):
        """Should format successful cancellation result."""
        mock_api.return_value = {
            "data": {
                "job_id": "12345",
                "status": "cancelled"
            }
        }

        result = cancel_job("owens", "12345")

        assert "cancelled" in result.lower() or "canceled" in result.lower()
        assert "12345" in result

    @patch("server.api_request")
    def test_empty_cluster_id_returns_error(self, mock_api):
        """Should return error for empty cluster ID."""
        mock_api.return_value = {"error": "bad_request", "message": "cluster parameter is required"}

        result = cancel_job("", "12345")

        assert "Error" in result

    @patch("server.api_request")
    def test_empty_job_id_returns_error(self, mock_api):
        """Should return error for empty job ID."""
        mock_api.return_value = {"error": "not_found", "message": "Job not found"}

        result = cancel_job("owens", "")

        assert "Error" in result

    @patch("server.api_request")
    def test_handles_cancellation_error(self, mock_api):
        """Should return error for cancellation failures."""
        mock_api.return_value = {"error": "unprocessable_entity", "message": "Permission denied"}

        result = cancel_job("owens", "12345")

        assert "Error" in result


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
