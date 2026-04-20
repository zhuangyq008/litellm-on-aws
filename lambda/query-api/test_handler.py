import json
import os
import pytest
from unittest.mock import patch, MagicMock


@pytest.fixture(autouse=True)
def set_env():
    os.environ["ATHENA_DATABASE"] = "litellm_gw_audit"
    os.environ["ATHENA_TABLE"] = "audit_logs"
    os.environ["ATHENA_WORKGROUP"] = "litellm-gw-audit"
    os.environ["S3_OUTPUT_LOCATION"] = "s3://test-bucket/athena-results/"
    yield
    for k in ("ATHENA_DATABASE", "ATHENA_TABLE", "ATHENA_WORKGROUP", "S3_OUTPUT_LOCATION"):
        del os.environ[k]


class TestSubmitQuery:
    def test_returns_execution_id(self):
        from handler import handler

        event = {
            "httpMethod": "POST",
            "path": "/api/query",
            "body": json.dumps({
                "start_date": "2026-04-01",
                "end_date": "2026-04-20",
            }),
        }

        mock_athena = MagicMock()
        mock_athena.start_query_execution.return_value = {
            "QueryExecutionId": "exec-abc-123"
        }
        with patch("handler.athena", mock_athena):
            result = handler(event, None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["execution_id"] == "exec-abc-123"

    def test_rejects_missing_dates(self):
        from handler import handler

        event = {
            "httpMethod": "POST",
            "path": "/api/query",
            "body": json.dumps({}),
        }

        result = handler(event, None)
        assert result["statusCode"] == 400


class TestGetResults:
    def test_returns_running_status(self):
        from handler import handler

        event = {
            "httpMethod": "GET",
            "path": "/api/query/exec-abc-123",
            "pathParameters": {"proxy": "query/exec-abc-123"},
        }

        mock_athena = MagicMock()
        mock_athena.get_query_execution.return_value = {
            "QueryExecution": {"Status": {"State": "RUNNING"}}
        }
        with patch("handler.athena", mock_athena):
            result = handler(event, None)

        body = json.loads(result["body"])
        assert body["status"] == "RUNNING"
        assert "results" not in body

    def test_returns_succeeded_with_results(self):
        from handler import handler

        event = {
            "httpMethod": "GET",
            "path": "/api/query/exec-abc-123",
            "pathParameters": {"proxy": "query/exec-abc-123"},
        }

        mock_athena = MagicMock()
        mock_athena.get_query_execution.return_value = {
            "QueryExecution": {"Status": {"State": "SUCCEEDED"}}
        }
        mock_athena.get_query_results.return_value = {
            "ResultSet": {
                "ResultSetMetadata": {
                    "ColumnInfo": [
                        {"Name": "id"},
                        {"Name": "model"},
                    ]
                },
                "Rows": [
                    {"Data": [{"VarCharValue": "id"}, {"VarCharValue": "model"}]},
                    {"Data": [{"VarCharValue": "req-001"}, {"VarCharValue": "opus"}]},
                ],
            }
        }
        with patch("handler.athena", mock_athena):
            result = handler(event, None)

        body = json.loads(result["body"])
        assert body["status"] == "SUCCEEDED"
        assert len(body["results"]) == 1
        assert body["results"][0]["id"] == "req-001"
        assert body["results"][0]["model"] == "opus"


class TestOptionsHandler:
    def test_returns_cors_headers(self):
        from handler import handler

        event = {
            "httpMethod": "OPTIONS",
            "path": "/api/query",
        }

        result = handler(event, None)
        assert result["statusCode"] == 200
        assert "Access-Control-Allow-Origin" in result["headers"]
