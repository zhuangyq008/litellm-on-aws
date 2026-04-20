import json
import os
import pytest
from unittest.mock import patch, MagicMock
from datetime import datetime


@pytest.fixture(autouse=True)
def set_env():
    os.environ["AUDIT_BUCKET"] = "test-audit-bucket"
    yield
    del os.environ["AUDIT_BUCKET"]


class TestHandler:
    def test_processes_insert_event_and_writes_to_s3(self):
        from handler import handler

        event = {
            "Records": [
                {
                    "eventName": "INSERT",
                    "dynamodb": {
                        "NewImage": {
                            "id": {"S": "req-001"},
                            "startTime": {"S": "2026-04-20 10:30:00.000000"},
                            "endTime": {"S": "2026-04-20 10:30:01.000000"},
                            "call_type": {"S": "acompletion"},
                            "model": {"S": "claude-opus-4-6"},
                            "messages": {"S": str([{"role": "user", "content": "test"}])},
                            "response": {"S": "ModelResponse(choices=[Choices(finish_reason='stop', index=0, message=Message(content='ok', role='assistant', tool_calls=None))])"},
                            "usage": {"S": "Usage(completion_tokens=1, prompt_tokens=2, total_tokens=3, completion_tokens_details=CompletionTokensDetailsWrapper(reasoning_tokens=0), prompt_tokens_details=PromptTokensDetailsWrapper(cached_tokens=0))"},
                            "metadata": {"S": str({})},
                            "modelParameters": {"S": str({"stream": True})},
                        }
                    },
                }
            ]
        }

        mock_s3 = MagicMock()
        with patch("handler.s3", mock_s3):
            result = handler(event, None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["processed"] == 1
        assert body["errors"] == 0

        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-audit-bucket"
        assert call_kwargs["Key"].startswith("logs/year=2026/month=04/day=20/")
        assert call_kwargs["Key"].endswith(".json")
        assert call_kwargs["ContentType"] == "application/json"

        written_data = call_kwargs["Body"]
        record = json.loads(written_data.strip())
        assert record["id"] == "req-001"
        assert record["model"] == "claude-opus-4-6"

    def test_skips_remove_events(self):
        from handler import handler

        event = {
            "Records": [
                {
                    "eventName": "REMOVE",
                    "dynamodb": {"OldImage": {"id": {"S": "old-001"}}},
                }
            ]
        }

        mock_s3 = MagicMock()
        with patch("handler.s3", mock_s3):
            result = handler(event, None)

        body = json.loads(result["body"])
        assert body["processed"] == 0
        mock_s3.put_object.assert_not_called()

    def test_writes_errors_to_error_prefix(self):
        from handler import handler

        event = {
            "Records": [
                {
                    "eventName": "INSERT",
                    "dynamodb": {
                        "NewImage": {
                            "id": {"S": "bad-001"},
                        }
                    },
                }
            ]
        }

        mock_s3 = MagicMock()
        with patch("handler.s3", mock_s3):
            result = handler(event, None)

        body = json.loads(result["body"])
        assert body["processed"] == 0
        assert body["errors"] == 1

        call_kwargs = mock_s3.put_object.call_args[1]
        assert "errors/" in call_kwargs["Key"]
