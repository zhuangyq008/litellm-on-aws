# Audit Log Visualization & Query System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CloudTrail-style audit log query system with DynamoDB Streams → S3 → Athena data pipeline, serverless Query API, Cognito authentication, and React SPA frontend.

**Architecture:** DynamoDB Streams feed a Lambda that transforms audit records to structured NDJSON in S3 (Hive-partitioned). Glue Catalog exposes the data to Athena. A separate Lambda behind API Gateway + Cognito Authorizer provides query endpoints. A React SPA on S3/CloudFront is the admin UI.

**Tech Stack:** AWS CloudFormation, Python 3.12 (Lambda), Athena/Glue, Cognito, API Gateway, React + Vite + Tailwind CSS

**Spec:** `docs/superpowers/specs/2026-04-20-audit-log-visualization-design.md`

---

## File Structure

### New Files

```
lambda/
  stream-processor/
    handler.py          # DynamoDB Stream → S3 writer (field extraction, NDJSON output)
    parser.py           # Parsing logic: ast.literal_eval for dicts, regex for repr strings
    test_parser.py      # Unit tests for parsing logic
    test_handler.py     # Unit tests for handler (mocked S3)
    requirements.txt    # boto3 (bundled in Lambda runtime, listed for local dev)

  query-api/
    handler.py          # API Gateway → Athena query builder + result fetcher
    query_builder.py    # SQL construction with parameterized filters + partition pruning
    test_query_builder.py # Unit tests for SQL generation
    test_handler.py     # Unit tests for handler (mocked Athena)
    requirements.txt    # boto3

audit-ui/
  package.json
  vite.config.js
  postcss.config.js
  tailwind.config.js
  index.html
  public/
    favicon.ico
  src/
    main.jsx            # React entry point
    App.jsx             # Router + auth guard
    config.js           # API endpoint, Cognito pool/client IDs (from env vars at build time)
    hooks/
      useAuth.js        # Cognito auth hook (login, logout, token refresh)
      useAuditQuery.js  # Query submission + polling hook
    components/
      Layout.jsx        # Top nav bar with user info + logout
      FilterBar.jsx     # Two-row filter form
      ResultsTable.jsx  # Audit log table with sortable columns
      DetailPanel.jsx   # Expandable record detail (9-box + tabs)
      Pagination.jsx    # Page navigation

cfn/
  06-audit-pipeline.yaml  # S3 bucket, Stream Lambda, Glue DB/Table, Athena Workgroup
  07-audit-ui.yaml        # Cognito, API Gateway, Query Lambda, SPA S3 bucket, CloudFront
```

### Modified Files

```
cfn/03-data.yaml          # Add StreamSpecification + export Stream ARN
deploy.sh                 # Add steps for Lambda packaging, stack 06/07 deployment, SPA build/upload
.gitignore                # Add audit-ui/node_modules/, audit-ui/dist/, .superpowers/
```

---

## Task 1: Enable DynamoDB Streams on Existing Table

**Files:**
- Modify: `cfn/03-data.yaml:119-141` (AuditLogTable resource)
- Modify: `cfn/03-data.yaml:161-179` (Outputs section)

- [ ] **Step 1: Add StreamSpecification to AuditLogTable**

In `cfn/03-data.yaml`, add `StreamSpecification` to the `AuditLogTable` resource (after line 133, the KeySchema block):

```yaml
    StreamSpecification:
      StreamViewType: NEW_IMAGE
```

The full resource should look like:

```yaml
  AuditLogTable:
    Type: AWS::DynamoDB::Table
    Properties:
      TableName: !Sub "${ProjectName}-audit-log"
      BillingMode: PAY_PER_REQUEST
      AttributeDefinitions:
        - AttributeName: id
          AttributeType: S
        - AttributeName: startTime
          AttributeType: S
      KeySchema:
        - AttributeName: id
          KeyType: HASH
        - AttributeName: startTime
          KeyType: RANGE
      StreamSpecification:
        StreamViewType: NEW_IMAGE
      TimeToLiveSpecification:
        AttributeName: ttl
        Enabled: true
      PointInTimeRecoverySpecification:
        PointInTimeRecoveryEnabled: true
      Tags:
        - Key: Name
          Value: !Sub "${ProjectName}-audit-log"
```

- [ ] **Step 2: Add Stream ARN to Outputs**

Add after the existing `AuditLogTableArn` output (after line 179):

```yaml
  AuditLogTableStreamArn:
    Value: !GetAtt AuditLogTable.StreamArn
    Export:
      Name: !Sub "${ProjectName}-AuditLogTableStreamArn"
```

- [ ] **Step 3: Validate the template**

Run:
```bash
aws cloudformation validate-template --template-body file://cfn/03-data.yaml --region us-east-1
```
Expected: `Parameters` and `Description` fields returned, no error.

- [ ] **Step 4: Commit**

```bash
git add cfn/03-data.yaml
git commit -m "feat: enable DynamoDB Streams on audit log table"
```

---

## Task 2: Stream Processor — Parsing Logic (TDD)

**Files:**
- Create: `lambda/stream-processor/parser.py`
- Create: `lambda/stream-processor/test_parser.py`
- Create: `lambda/stream-processor/requirements.txt`

This task implements the core parsing logic that converts DynamoDB audit records (Python repr strings) into structured JSON. The fields `messages`, `metadata`, `modelParameters` are Python dict/list strings parseable by `ast.literal_eval`. The fields `response` and `usage` are LiteLLM object repr strings (e.g., `ModelResponse(...)`, `Usage(...)`) that require regex extraction.

- [ ] **Step 1: Create requirements.txt**

Create `lambda/stream-processor/requirements.txt`:

```
boto3>=1.34.0
pytest>=8.0.0
```

- [ ] **Step 2: Write failing tests for parse_usage**

Create `lambda/stream-processor/test_parser.py`:

```python
import pytest
from parser import parse_usage, parse_response, parse_messages, parse_metadata, transform_record


class TestParseUsage:
    def test_extracts_token_counts(self):
        usage_str = (
            "Usage(completion_tokens=82, prompt_tokens=42742, total_tokens=42824, "
            "completion_tokens_details=CompletionTokensDetailsWrapper("
            "accepted_prediction_tokens=None, audio_tokens=None, reasoning_tokens=0, "
            "rejected_prediction_tokens=None, text_tokens=82, image_tokens=None, "
            "video_tokens=None), prompt_tokens_details=PromptTokensDetailsWrapper("
            "audio_tokens=None, cached_tokens=42510, text_tokens=None, "
            "image_tokens=None, video_tokens=None, cache_creation_tokens=231), "
            "cache_creation_input_tokens=231, cache_read_input_tokens=42510)"
        )
        result = parse_usage(usage_str)
        assert result["completion_tokens"] == 82
        assert result["prompt_tokens"] == 42742
        assert result["total_tokens"] == 42824
        assert result["cached_tokens"] == 42510
        assert result["reasoning_tokens"] == 0

    def test_handles_missing_cached_tokens(self):
        usage_str = (
            "Usage(completion_tokens=4, prompt_tokens=12, total_tokens=16, "
            "completion_tokens_details=CompletionTokensDetailsWrapper("
            "reasoning_tokens=0), prompt_tokens_details=PromptTokensDetailsWrapper("
            "cached_tokens=0))"
        )
        result = parse_usage(usage_str)
        assert result["completion_tokens"] == 4
        assert result["prompt_tokens"] == 12
        assert result["total_tokens"] == 16
        assert result["cached_tokens"] == 0
        assert result["reasoning_tokens"] == 0

    def test_returns_zeros_on_unparseable_input(self):
        result = parse_usage("garbage data")
        assert result["completion_tokens"] == 0
        assert result["prompt_tokens"] == 0
        assert result["total_tokens"] == 0
        assert result["cached_tokens"] == 0
        assert result["reasoning_tokens"] == 0
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseUsage -v
```
Expected: `ModuleNotFoundError: No module named 'parser'` or `ImportError`.

- [ ] **Step 4: Implement parse_usage**

Create `lambda/stream-processor/parser.py`:

```python
import re
import ast
import json


def _extract_int(text, pattern, default=0):
    match = re.search(pattern, text)
    if match:
        return int(match.group(1))
    return default


def parse_usage(usage_str):
    if not usage_str or not isinstance(usage_str, str):
        return {
            "completion_tokens": 0,
            "prompt_tokens": 0,
            "total_tokens": 0,
            "cached_tokens": 0,
            "reasoning_tokens": 0,
        }
    return {
        "completion_tokens": _extract_int(usage_str, r"(?<!\w)completion_tokens=(\d+)"),
        "prompt_tokens": _extract_int(usage_str, r"(?<!\w)prompt_tokens=(\d+)"),
        "total_tokens": _extract_int(usage_str, r"(?<!\w)total_tokens=(\d+)"),
        "cached_tokens": _extract_int(usage_str, r"cached_tokens=(\d+)"),
        "reasoning_tokens": _extract_int(usage_str, r"reasoning_tokens=(\d+)"),
    }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseUsage -v
```
Expected: 3 tests PASS.

- [ ] **Step 6: Write failing tests for parse_response**

Append to `lambda/stream-processor/test_parser.py`:

```python
class TestParseResponse:
    def test_extracts_finish_reason_and_content(self):
        response_str = (
            "ModelResponse(id='abc-123', created=1776567341, "
            "model='us.anthropic.claude-opus-4-6-v1', object='chat.completion', "
            "system_fingerprint=None, choices=[Choices(finish_reason='stop', index=0, "
            "message=Message(content='Hello world, this is a test response.', "
            "role='assistant', tool_calls=None, function_call=None, "
            "provider_specific_fields=None))], usage=Usage(completion_tokens=10))"
        )
        result = parse_response(response_str)
        assert result["finish_reason"] == "stop"
        assert result["response_preview"] == "Hello world, this is a test response."
        assert result["has_tool_calls"] is False
        assert result["tool_names"] == []

    def test_extracts_tool_calls(self):
        response_str = (
            "ModelResponse(id='abc-123', created=1776567341, "
            "model='us.anthropic.claude-opus-4-6-v1', object='chat.completion', "
            "choices=[Choices(finish_reason='stop', index=0, "
            "message=Message(content='', role='assistant', "
            "tool_calls=[ChatCompletionMessageToolCall("
            "function=Function(arguments='{\"command\": \"ls\"}', name='Bash'), "
            "id='tool_1', type='function'), "
            "ChatCompletionMessageToolCall("
            "function=Function(arguments='{\"path\": \"/tmp\"}', name='Read'), "
            "id='tool_2', type='function')]))])"
        )
        result = parse_response(response_str)
        assert result["has_tool_calls"] is True
        assert result["tool_names"] == ["Bash", "Read"]

    def test_truncates_long_preview(self):
        long_content = "x" * 1000
        response_str = (
            f"ModelResponse(choices=[Choices(finish_reason='stop', index=0, "
            f"message=Message(content='{long_content}', role='assistant', "
            f"tool_calls=None))])"
        )
        result = parse_response(response_str)
        assert len(result["response_preview"]) == 500

    def test_returns_defaults_on_unparseable(self):
        result = parse_response("garbage")
        assert result["finish_reason"] == "unknown"
        assert result["response_preview"] == ""
        assert result["has_tool_calls"] is False
        assert result["tool_names"] == []
```

- [ ] **Step 7: Run tests to verify they fail**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseResponse -v
```
Expected: FAIL (function not defined yet).

- [ ] **Step 8: Implement parse_response**

Append to `lambda/stream-processor/parser.py`:

```python
def parse_response(response_str):
    defaults = {
        "finish_reason": "unknown",
        "response_preview": "",
        "has_tool_calls": False,
        "tool_names": [],
    }
    if not response_str or not isinstance(response_str, str):
        return defaults

    try:
        finish = re.search(r"finish_reason='(\w+)'", response_str)
        finish_reason = finish.group(1) if finish else "unknown"

        content_match = re.search(r"message=Message\(content='(.*?)'(?:,\s*role=)", response_str, re.DOTALL)
        if not content_match:
            content_match = re.search(r"content='(.*?)'", response_str, re.DOTALL)
        preview = content_match.group(1) if content_match else ""
        if len(preview) > 500:
            preview = preview[:500]

        tool_names = re.findall(r"name='(\w+)'\)", response_str)
        # Filter out non-tool names that might match (e.g., from message content)
        # Tool names appear inside Function(..., name='X')
        tool_names_in_functions = re.findall(r"Function\(arguments=.*?, name='(\w+)'\)", response_str, re.DOTALL)
        if tool_names_in_functions:
            tool_names = list(dict.fromkeys(tool_names_in_functions))
        else:
            tool_names = []

        has_tool_calls = len(tool_names) > 0

        return {
            "finish_reason": finish_reason,
            "response_preview": preview,
            "has_tool_calls": has_tool_calls,
            "tool_names": tool_names,
        }
    except Exception:
        return defaults
```

- [ ] **Step 9: Run tests to verify they pass**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseResponse -v
```
Expected: 4 tests PASS.

- [ ] **Step 10: Write failing tests for parse_messages**

Append to `lambda/stream-processor/test_parser.py`:

```python
class TestParseMessages:
    def test_extracts_message_count_and_preview(self):
        messages_str = str([
            {"role": "user", "content": [{"type": "text", "text": "Hello, help me with this code"}]},
            {"role": "assistant", "content": [{"type": "text", "text": "Sure, I can help."}]},
            {"role": "user", "content": "What about testing?"},
        ])
        result = parse_messages(messages_str)
        assert result["message_count"] == 3
        assert result["user_message_preview"] == "What about testing?"

    def test_extracts_text_from_content_blocks(self):
        messages_str = str([
            {"role": "user", "content": [
                {"type": "text", "text": "First block"},
                {"type": "text", "text": "Second block with the actual question"},
            ]},
        ])
        result = parse_messages(messages_str)
        assert result["message_count"] == 1
        assert "Second block" in result["user_message_preview"]

    def test_truncates_long_preview(self):
        long_text = "y" * 1000
        messages_str = str([{"role": "user", "content": long_text}])
        result = parse_messages(messages_str)
        assert len(result["user_message_preview"]) == 500

    def test_returns_defaults_on_unparseable(self):
        result = parse_messages("not a list")
        assert result["message_count"] == 0
        assert result["user_message_preview"] == ""
```

- [ ] **Step 11: Run tests to verify they fail**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseMessages -v
```
Expected: FAIL.

- [ ] **Step 12: Implement parse_messages**

Append to `lambda/stream-processor/parser.py`:

```python
def _extract_user_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                texts.append(block.get("text", ""))
        return texts[-1] if texts else ""
    return ""


def parse_messages(messages_str):
    defaults = {"message_count": 0, "user_message_preview": ""}
    if not messages_str or not isinstance(messages_str, str):
        return defaults
    try:
        messages = ast.literal_eval(messages_str)
        if not isinstance(messages, list):
            return defaults

        last_user_text = ""
        for msg in messages:
            if isinstance(msg, dict) and msg.get("role") == "user":
                text = _extract_user_text(msg.get("content", ""))
                if text:
                    last_user_text = text

        if len(last_user_text) > 500:
            last_user_text = last_user_text[:500]

        return {
            "message_count": len(messages),
            "user_message_preview": last_user_text,
        }
    except Exception:
        return defaults
```

- [ ] **Step 13: Run tests to verify they pass**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseMessages -v
```
Expected: 4 tests PASS.

- [ ] **Step 14: Write failing tests for parse_metadata**

Append to `lambda/stream-processor/test_parser.py`:

```python
class TestParseMetadata:
    def test_extracts_device_and_session_from_nested_json(self):
        metadata_str = str({
            "user_id": '{"device_id":"8d6ae821abc","account_uuid":"","session_id":"f61cee15-d6a2"}'
        })
        result = parse_metadata(metadata_str)
        assert result["device_id"] == "8d6ae821abc"
        assert result["session_id"] == "f61cee15-d6a2"
        assert result["source_ip"] == ""

    def test_extracts_source_ip_from_headers(self):
        metadata_str = str({
            "user_api_key_user_id": "default_user_id",
            "headers": {
                "x-forwarded-for": "44.219.177.250, 15.158.254.78",
                "host": "d2cyolr4rt91j1.cloudfront.net",
            },
        })
        result = parse_metadata(metadata_str)
        assert result["source_ip"] == "44.219.177.250"

    def test_returns_defaults_on_unparseable(self):
        result = parse_metadata("not a dict")
        assert result["device_id"] == ""
        assert result["session_id"] == ""
        assert result["source_ip"] == ""
```

- [ ] **Step 15: Run tests to verify they fail**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseMetadata -v
```
Expected: FAIL.

- [ ] **Step 16: Implement parse_metadata**

Append to `lambda/stream-processor/parser.py`:

```python
def parse_metadata(metadata_str):
    defaults = {"device_id": "", "session_id": "", "source_ip": ""}
    if not metadata_str or not isinstance(metadata_str, str):
        return defaults
    try:
        metadata = ast.literal_eval(metadata_str)
        if not isinstance(metadata, dict):
            return defaults

        device_id = ""
        session_id = ""
        source_ip = ""

        user_id_str = metadata.get("user_id", "")
        if isinstance(user_id_str, str) and user_id_str.startswith("{"):
            try:
                user_id_obj = json.loads(user_id_str)
                device_id = user_id_obj.get("device_id", "")
                session_id = user_id_obj.get("session_id", "")
            except json.JSONDecodeError:
                pass

        headers = metadata.get("headers", {})
        if isinstance(headers, dict):
            forwarded = headers.get("x-forwarded-for", "")
            if forwarded:
                source_ip = forwarded.split(",")[0].strip()

        return {
            "device_id": device_id,
            "session_id": session_id,
            "source_ip": source_ip,
        }
    except Exception:
        return defaults
```

- [ ] **Step 17: Run tests to verify they pass**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestParseMetadata -v
```
Expected: 3 tests PASS.

- [ ] **Step 18: Write failing test for transform_record (integration of all parsers)**

Append to `lambda/stream-processor/test_parser.py`:

```python
class TestTransformRecord:
    def test_transforms_full_dynamodb_record(self):
        record = {
            "id": {"S": "abc-123"},
            "startTime": {"S": "2026-04-20 01:14:32.376335"},
            "endTime": {"S": "2026-04-20 01:14:33.100000"},
            "call_type": {"S": "anthropic_messages"},
            "model": {"S": "us.anthropic.claude-opus-4-6-v1"},
            "messages": {"S": str([{"role": "user", "content": "Hello"}])},
            "response": {"S": (
                "ModelResponse(id='abc-123', choices=[Choices("
                "finish_reason='stop', index=0, message=Message("
                "content='Hi there', role='assistant', tool_calls=None))])"
            )},
            "usage": {"S": (
                "Usage(completion_tokens=10, prompt_tokens=5, total_tokens=15, "
                "completion_tokens_details=CompletionTokensDetailsWrapper("
                "reasoning_tokens=0), prompt_tokens_details="
                "PromptTokensDetailsWrapper(cached_tokens=3))"
            )},
            "metadata": {"S": str({"user_id": '{"device_id":"dev1","session_id":"sess1"}'})},
            "modelParameters": {"S": str({"max_tokens": 64000, "stream": True})},
        }
        result = transform_record(record)

        assert result["id"] == "abc-123"
        assert result["start_time"] == "2026-04-20 01:14:32.376335"
        assert result["end_time"] == "2026-04-20 01:14:33.100000"
        assert result["call_type"] == "anthropic_messages"
        assert result["model"] == "us.anthropic.claude-opus-4-6-v1"
        assert result["completion_tokens"] == 10
        assert result["prompt_tokens"] == 5
        assert result["total_tokens"] == 15
        assert result["cached_tokens"] == 3
        assert result["reasoning_tokens"] == 0
        assert result["finish_reason"] == "stop"
        assert result["response_preview"] == "Hi there"
        assert result["has_tool_calls"] is False
        assert result["tool_names"] == []
        assert result["message_count"] == 1
        assert result["user_message_preview"] == "Hello"
        assert result["device_id"] == "dev1"
        assert result["session_id"] == "sess1"
        assert result["source_ip"] == ""
        assert "raw_messages" in result
        assert "raw_response" in result
        assert "raw_metadata" in result
        assert "raw_model_parameters" in result
```

- [ ] **Step 19: Run test to verify it fails**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py::TestTransformRecord -v
```
Expected: FAIL.

- [ ] **Step 20: Implement transform_record**

Append to `lambda/stream-processor/parser.py`:

```python
def _get_s(record, key):
    return record.get(key, {}).get("S", "")


def transform_record(record):
    usage = parse_usage(_get_s(record, "usage"))
    response = parse_response(_get_s(record, "response"))
    messages = parse_messages(_get_s(record, "messages"))
    metadata = parse_metadata(_get_s(record, "metadata"))

    return {
        "id": _get_s(record, "id"),
        "call_type": _get_s(record, "call_type"),
        "model": _get_s(record, "model"),
        "start_time": _get_s(record, "startTime"),
        "end_time": _get_s(record, "endTime"),
        **usage,
        **response,
        **messages,
        **metadata,
        "raw_messages": _get_s(record, "messages"),
        "raw_response": _get_s(record, "response"),
        "raw_metadata": _get_s(record, "metadata"),
        "raw_model_parameters": _get_s(record, "modelParameters"),
    }
```

- [ ] **Step 21: Run all parser tests**

```bash
cd lambda/stream-processor && python -m pytest test_parser.py -v
```
Expected: All 15 tests PASS.

- [ ] **Step 22: Commit**

```bash
git add lambda/stream-processor/parser.py lambda/stream-processor/test_parser.py lambda/stream-processor/requirements.txt
git commit -m "feat: add audit log record parser with field extraction"
```

---

## Task 3: Stream Processor — Lambda Handler

**Files:**
- Create: `lambda/stream-processor/handler.py`
- Create: `lambda/stream-processor/test_handler.py`

- [ ] **Step 1: Write failing test for Lambda handler**

Create `lambda/stream-processor/test_handler.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd lambda/stream-processor && python -m pytest test_handler.py -v
```
Expected: FAIL.

- [ ] **Step 3: Implement the handler**

Create `lambda/stream-processor/handler.py`:

```python
import os
import json
import time
import uuid
import logging
import boto3
from datetime import datetime

from parser import transform_record

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

BUCKET = os.environ.get("AUDIT_BUCKET", "")


def _s3_key(prefix, start_time_str):
    try:
        dt = datetime.strptime(start_time_str[:10], "%Y-%m-%d")
    except (ValueError, TypeError):
        dt = datetime.utcnow()
    ts = int(time.time() * 1000)
    batch_id = uuid.uuid4().hex[:8]
    return f"{prefix}/year={dt.year}/month={dt.month:02d}/day={dt.day:02d}/{ts}-{batch_id}.json"


def handler(event, context):
    records = event.get("Records", [])
    processed_lines = []
    error_lines = []

    for record in records:
        if record.get("eventName") not in ("INSERT", "MODIFY"):
            continue

        new_image = record.get("dynamodb", {}).get("NewImage", {})

        try:
            transformed = transform_record(new_image)
            if not transformed.get("id"):
                raise ValueError("Record missing id field")
            processed_lines.append(json.dumps(transformed, ensure_ascii=False))
        except Exception as e:
            logger.error(f"Failed to transform record: {e}")
            error_entry = {
                "error": str(e),
                "raw_record": json.dumps(
                    {k: v for k, v in new_image.items() if k in ("id", "startTime", "model", "call_type")},
                    default=str,
                ),
            }
            error_lines.append(json.dumps(error_entry, ensure_ascii=False))

    start_time = ""
    if records:
        first_image = records[0].get("dynamodb", {}).get("NewImage", {})
        start_time = first_image.get("startTime", {}).get("S", "")

    if processed_lines:
        key = _s3_key("logs", start_time)
        body = "\n".join(processed_lines)
        s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType="application/json")
        logger.info(f"Wrote {len(processed_lines)} records to s3://{BUCKET}/{key}")

    if error_lines:
        key = _s3_key("errors", start_time)
        body = "\n".join(error_lines)
        s3.put_object(Bucket=BUCKET, Key=key, Body=body, ContentType="application/json")
        logger.warning(f"Wrote {len(error_lines)} error records to s3://{BUCKET}/{key}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "processed": len(processed_lines),
            "errors": len(error_lines),
        }),
    }
```

- [ ] **Step 4: Run all tests**

```bash
cd lambda/stream-processor && python -m pytest test_handler.py test_parser.py -v
```
Expected: All 18 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lambda/stream-processor/handler.py lambda/stream-processor/test_handler.py
git commit -m "feat: add stream processor Lambda handler"
```

---

## Task 4: CloudFormation Stack 06 — Audit Pipeline

**Files:**
- Create: `cfn/06-audit-pipeline.yaml`

This stack creates: S3 audit bucket with lifecycle policies, Stream Processor Lambda with DynamoDB Streams trigger, Glue Database + Table, Athena Workgroup, and all required IAM roles.

- [ ] **Step 1: Create 06-audit-pipeline.yaml**

Create `cfn/06-audit-pipeline.yaml`:

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: "Audit Log Pipeline - S3, Lambda (DynamoDB Streams), Glue, Athena"

Parameters:
  ProjectName:
    Type: String
    Default: litellm-gw

Resources:
  # --- S3 Audit Bucket ---
  AuditBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${ProjectName}-audit-${AWS::AccountId}"
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      LifecycleConfiguration:
        Rules:
          - Id: DeleteLogsAfter90Days
            Status: Enabled
            Prefix: logs/
            ExpirationInDays: 90
          - Id: DeleteErrorsAfter180Days
            Status: Enabled
            Prefix: errors/
            ExpirationInDays: 180
          - Id: DeleteAthenaResultsAfter7Days
            Status: Enabled
            Prefix: athena-results/
            ExpirationInDays: 7

  # --- Stream Processor Lambda Role ---
  StreamProcessorRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-stream-processor-role"
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: DynamoDBStreamRead
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - dynamodb:GetRecords
                  - dynamodb:GetShardIterator
                  - dynamodb:DescribeStream
                  - dynamodb:ListStreams
                Resource:
                  Fn::ImportValue: !Sub "${ProjectName}-AuditLogTableStreamArn"
        - PolicyName: S3Write
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - s3:PutObject
                Resource: !Sub "arn:aws:s3:::${AuditBucket}/*"

  # --- Stream Processor Lambda ---
  StreamProcessorFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Sub "${ProjectName}-stream-processor"
      Runtime: python3.12
      Handler: handler.handler
      MemorySize: 256
      Timeout: 60
      Role: !GetAtt StreamProcessorRole.Arn
      Code:
        S3Bucket:
          Fn::ImportValue: !Sub "${ProjectName}-ConfigBucketName"
        S3Key: lambda/stream-processor.zip
      Environment:
        Variables:
          AUDIT_BUCKET: !Ref AuditBucket

  # --- DynamoDB Stream Event Source Mapping ---
  StreamEventSourceMapping:
    Type: AWS::Lambda::EventSourceMapping
    Properties:
      EventSourceArn:
        Fn::ImportValue: !Sub "${ProjectName}-AuditLogTableStreamArn"
      FunctionName: !Ref StreamProcessorFunction
      StartingPosition: TRIM_HORIZON
      BatchSize: 100
      MaximumBatchingWindowInSeconds: 60
      Enabled: true

  # --- Glue Database ---
  AuditGlueDatabase:
    Type: AWS::Glue::Database
    Properties:
      CatalogId: !Ref AWS::AccountId
      DatabaseInput:
        Name: !Sub "${ProjectName}_audit"
        Description: "Audit log data for Athena queries"

  # --- Glue Table ---
  AuditGlueTable:
    Type: AWS::Glue::Table
    Properties:
      CatalogId: !Ref AWS::AccountId
      DatabaseName: !Ref AuditGlueDatabase
      TableInput:
        Name: audit_logs
        TableType: EXTERNAL_TABLE
        Parameters:
          classification: json
          "projection.enabled": "true"
          "projection.year.type": integer
          "projection.year.range": "2026,2030"
          "projection.month.type": integer
          "projection.month.range": "1,12"
          "projection.month.digits": "2"
          "projection.day.type": integer
          "projection.day.range": "1,31"
          "projection.day.digits": "2"
          "storage.location.template": !Sub "s3://${AuditBucket}/logs/year=$${year}/month=$${month}/day=$${day}"
        StorageDescriptor:
          Location: !Sub "s3://${AuditBucket}/logs/"
          InputFormat: org.apache.hadoop.mapred.TextInputFormat
          OutputFormat: org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat
          SerdeInfo:
            SerializationLibrary: org.openx.data.jsonserde.JsonSerDe
            Parameters:
              "serialization.format": "1"
          Columns:
            - Name: id
              Type: string
            - Name: call_type
              Type: string
            - Name: model
              Type: string
            - Name: start_time
              Type: string
            - Name: end_time
              Type: string
            - Name: completion_tokens
              Type: bigint
            - Name: prompt_tokens
              Type: bigint
            - Name: total_tokens
              Type: bigint
            - Name: cached_tokens
              Type: bigint
            - Name: reasoning_tokens
              Type: bigint
            - Name: finish_reason
              Type: string
            - Name: response_preview
              Type: string
            - Name: has_tool_calls
              Type: boolean
            - Name: tool_names
              Type: "array<string>"
            - Name: message_count
              Type: int
            - Name: user_message_preview
              Type: string
            - Name: device_id
              Type: string
            - Name: session_id
              Type: string
            - Name: source_ip
              Type: string
            - Name: raw_messages
              Type: string
            - Name: raw_response
              Type: string
            - Name: raw_metadata
              Type: string
            - Name: raw_model_parameters
              Type: string
        PartitionKeys:
          - Name: year
            Type: string
          - Name: month
            Type: string
          - Name: day
            Type: string

  # --- Athena Workgroup ---
  AuditAthenaWorkgroup:
    Type: AWS::Athena::WorkGroup
    Properties:
      Name: !Sub "${ProjectName}-audit"
      State: ENABLED
      WorkGroupConfiguration:
        ResultConfiguration:
          OutputLocation: !Sub "s3://${AuditBucket}/athena-results/"
        EnforceWorkGroupConfiguration: true
        PublishCloudWatchMetricsEnabled: true

Outputs:
  AuditBucketName:
    Value: !Ref AuditBucket
    Export:
      Name: !Sub "${ProjectName}-AuditBucketName"
  AuditBucketArn:
    Value: !GetAtt AuditBucket.Arn
    Export:
      Name: !Sub "${ProjectName}-AuditBucketArn"
  GlueDatabaseName:
    Value: !Ref AuditGlueDatabase
    Export:
      Name: !Sub "${ProjectName}-AuditGlueDatabaseName"
  AthenaWorkgroupName:
    Value: !Ref AuditAthenaWorkgroup
    Export:
      Name: !Sub "${ProjectName}-AuditAthenaWorkgroupName"
```

- [ ] **Step 2: Validate the template**

```bash
aws cloudformation validate-template --template-body file://cfn/06-audit-pipeline.yaml --region us-east-1
```
Expected: Valid template output.

- [ ] **Step 3: Commit**

```bash
git add cfn/06-audit-pipeline.yaml
git commit -m "feat: add CloudFormation stack for audit pipeline (S3, Lambda, Glue, Athena)"
```

---

## Task 5: Query API — SQL Builder (TDD)

**Files:**
- Create: `lambda/query-api/query_builder.py`
- Create: `lambda/query-api/test_query_builder.py`
- Create: `lambda/query-api/requirements.txt`

- [ ] **Step 1: Create requirements.txt**

Create `lambda/query-api/requirements.txt`:

```
boto3>=1.34.0
pytest>=8.0.0
```

- [ ] **Step 2: Write failing tests for build_query**

Create `lambda/query-api/test_query_builder.py`:

```python
import pytest
from query_builder import build_query


class TestBuildQuery:
    def test_basic_time_range_query(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-20",
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "SELECT" in sql
        assert "FROM mydb.audit_logs" in sql
        assert "year = '2026'" in sql
        assert "month = '04'" in sql
        assert "start_time >= '2026-04-01'" in sql
        assert "start_time < '2026-04-20'" in sql
        assert "ORDER BY start_time DESC" in sql
        assert "LIMIT 50" in sql
        assert "raw_messages" not in sql
        assert "raw_response" not in sql

    def test_cross_month_query_includes_both_months(self):
        params = {
            "start_date": "2026-03-25",
            "end_date": "2026-04-05",
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "(year = '2026' AND month = '03')" in sql or "month IN" in sql

    def test_model_filter(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "model": "us.anthropic.claude-opus-4-6-v1",
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "model = 'us.anthropic.claude-opus-4-6-v1'" in sql

    def test_multiple_filters(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "model": "claude-opus-4-6",
            "call_type": "anthropic_messages",
            "finish_reason": "stop",
            "has_tool_calls": True,
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "model = 'claude-opus-4-6'" in sql
        assert "call_type = 'anthropic_messages'" in sql
        assert "finish_reason = 'stop'" in sql
        assert "has_tool_calls = true" in sql

    def test_min_total_tokens_filter(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "min_total_tokens": 1000,
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "total_tokens >= 1000" in sql

    def test_keyword_filter(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "keyword": "error",
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "user_message_preview" in sql
        assert "response_preview" in sql
        assert "'%error%'" in sql.lower() or "LIKE" in sql

    def test_custom_page_size(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "page_size": 100,
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "LIMIT 100" in sql

    def test_page_size_capped_at_200(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "page_size": 9999,
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "LIMIT 200" in sql

    def test_sql_injection_prevented(self):
        params = {
            "start_date": "2026-04-01",
            "end_date": "2026-04-30",
            "model": "'; DROP TABLE audit_logs; --",
        }
        sql = build_query(params, "mydb", "audit_logs")
        assert "DROP" not in sql
        assert ";" not in sql.rstrip(";").rstrip()


class TestBuildRecordQuery:
    def test_builds_single_record_query(self):
        from query_builder import build_record_query
        sql = build_record_query("abc-123", "mydb", "audit_logs")
        assert "SELECT *" in sql
        assert "FROM mydb.audit_logs" in sql
        assert "id = 'abc-123'" in sql
        assert "LIMIT 1" in sql
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd lambda/query-api && python -m pytest test_query_builder.py -v
```
Expected: FAIL.

- [ ] **Step 4: Implement query_builder.py**

Create `lambda/query-api/query_builder.py`:

```python
import re
from datetime import datetime, timedelta


def _sanitize(value):
    if not isinstance(value, str):
        return str(value)
    return re.sub(r"[;'\\\-\-]", "", value)


def _generate_partition_filter(start_date, end_date):
    start = datetime.strptime(start_date, "%Y-%m-%d")
    end = datetime.strptime(end_date, "%Y-%m-%d")

    partitions = []
    current = start.replace(day=1)
    while current <= end:
        partitions.append((str(current.year), f"{current.month:02d}")  )
        if current.month == 12:
            current = current.replace(year=current.year + 1, month=1)
        else:
            current = current.replace(month=current.month + 1)

    if len(partitions) == 1:
        year, month = partitions[0]
        return f"year = '{year}' AND month = '{month}'"

    clauses = [f"(year = '{y}' AND month = '{m}')" for y, m in partitions]
    return "(" + " OR ".join(clauses) + ")"


LIST_COLUMNS = (
    "id, call_type, model, start_time, end_time, "
    "completion_tokens, prompt_tokens, total_tokens, cached_tokens, reasoning_tokens, "
    "finish_reason, response_preview, has_tool_calls, tool_names, "
    "message_count, user_message_preview, "
    "device_id, session_id, source_ip"
)


def build_query(params, database, table):
    start_date = _sanitize(params.get("start_date", ""))
    end_date = _sanitize(params.get("end_date", ""))

    conditions = []
    conditions.append(_generate_partition_filter(start_date, end_date))
    conditions.append(f"start_time >= '{start_date}'")
    conditions.append(f"start_time < '{end_date}'")

    for field in ("model", "call_type", "session_id", "device_id", "source_ip", "finish_reason"):
        value = params.get(field)
        if value:
            conditions.append(f"{field} = '{_sanitize(value)}'")

    if params.get("has_tool_calls") is True:
        conditions.append("has_tool_calls = true")

    min_tokens = params.get("min_total_tokens")
    if min_tokens is not None:
        conditions.append(f"total_tokens >= {int(min_tokens)}")

    keyword = params.get("keyword")
    if keyword:
        safe_kw = _sanitize(keyword).lower()
        conditions.append(
            f"(LOWER(user_message_preview) LIKE '%{safe_kw}%' "
            f"OR LOWER(response_preview) LIKE '%{safe_kw}%')"
        )

    page_size = min(int(params.get("page_size", 50)), 200)

    where_clause = " AND ".join(conditions)

    return (
        f"SELECT {LIST_COLUMNS} "
        f"FROM {database}.{table} "
        f"WHERE {where_clause} "
        f"ORDER BY start_time DESC "
        f"LIMIT {page_size}"
    )


def build_record_query(record_id, database, table):
    safe_id = _sanitize(record_id)
    return (
        f"SELECT * "
        f"FROM {database}.{table} "
        f"WHERE id = '{safe_id}' "
        f"LIMIT 1"
    )
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd lambda/query-api && python -m pytest test_query_builder.py -v
```
Expected: All 11 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add lambda/query-api/query_builder.py lambda/query-api/test_query_builder.py lambda/query-api/requirements.txt
git commit -m "feat: add Athena SQL query builder with parameterized filters"
```

---

## Task 6: Query API — Lambda Handler

**Files:**
- Create: `lambda/query-api/handler.py`
- Create: `lambda/query-api/test_handler.py`

- [ ] **Step 1: Write failing tests for the handler**

Create `lambda/query-api/test_handler.py`:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd lambda/query-api && python -m pytest test_handler.py -v
```
Expected: FAIL.

- [ ] **Step 3: Implement the handler**

Create `lambda/query-api/handler.py`:

```python
import os
import json
import logging
import boto3

from query_builder import build_query, build_record_query

logger = logging.getLogger()
logger.setLevel(logging.INFO)

athena = boto3.client("athena")

DATABASE = os.environ.get("ATHENA_DATABASE", "")
TABLE = os.environ.get("ATHENA_TABLE", "")
WORKGROUP = os.environ.get("ATHENA_WORKGROUP", "")
OUTPUT_LOCATION = os.environ.get("S3_OUTPUT_LOCATION", "")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
}


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False, default=str),
    }


def _parse_route(event):
    method = event.get("httpMethod", "")
    path = event.get("path", "")
    path_params = event.get("pathParameters") or {}
    proxy = path_params.get("proxy", "")

    if method == "POST" and (path.endswith("/query") or proxy == "query"):
        return "submit_query", {}
    if method == "GET" and proxy.startswith("query/"):
        execution_id = proxy[len("query/"):]
        return "get_results", {"execution_id": execution_id}
    if method == "GET" and proxy.startswith("record/"):
        record_id = proxy[len("record/"):]
        return "get_record", {"record_id": record_id}
    if method == "OPTIONS":
        return "options", {}
    return "unknown", {}


def _submit_query(event):
    body = json.loads(event.get("body") or "{}")
    if not body.get("start_date") or not body.get("end_date"):
        return _response(400, {"error": "start_date and end_date are required"})

    sql = build_query(body, DATABASE, TABLE)
    logger.info(f"Executing Athena query: {sql}")

    result = athena.start_query_execution(
        QueryString=sql,
        WorkGroup=WORKGROUP,
        ResultConfiguration={"OutputLocation": OUTPUT_LOCATION},
    )
    return _response(200, {"execution_id": result["QueryExecutionId"]})


def _get_results(execution_id):
    exec_result = athena.get_query_execution(QueryExecutionId=execution_id)
    state = exec_result["QueryExecution"]["Status"]["State"]

    if state in ("QUEUED", "RUNNING"):
        return _response(200, {"status": state})

    if state == "FAILED":
        reason = exec_result["QueryExecution"]["Status"].get("StateChangeReason", "Unknown error")
        return _response(200, {"status": "FAILED", "error": reason})

    query_results = athena.get_query_results(QueryExecutionId=execution_id, MaxResults=201)
    rows = query_results["ResultSet"]["Rows"]
    columns = [col["Name"] for col in query_results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]]

    results = []
    for row in rows[1:]:
        record = {}
        for i, col in enumerate(columns):
            cell = row["Data"][i]
            record[col] = cell.get("VarCharValue", "")
        results.append(record)

    return _response(200, {"status": "SUCCEEDED", "results": results, "count": len(results)})


def _get_record(record_id):
    sql = build_record_query(record_id, DATABASE, TABLE)
    logger.info(f"Fetching record: {sql}")

    exec_result = athena.start_query_execution(
        QueryString=sql,
        WorkGroup=WORKGROUP,
        ResultConfiguration={"OutputLocation": OUTPUT_LOCATION},
    )
    execution_id = exec_result["QueryExecutionId"]

    import time
    for _ in range(30):
        status = athena.get_query_execution(QueryExecutionId=execution_id)
        state = status["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state == "FAILED":
            return _response(500, {"error": "Query failed"})
        time.sleep(1)

    query_results = athena.get_query_results(QueryExecutionId=execution_id)
    rows = query_results["ResultSet"]["Rows"]
    columns = [col["Name"] for col in query_results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]]

    if len(rows) < 2:
        return _response(404, {"error": "Record not found"})

    record = {}
    for i, col in enumerate(columns):
        cell = rows[1]["Data"][i]
        record[col] = cell.get("VarCharValue", "")

    return _response(200, {"record": record})


def handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return _response(200, {})

    route, params = _parse_route(event)

    if route == "submit_query":
        return _submit_query(event)
    elif route == "get_results":
        return _get_results(params["execution_id"])
    elif route == "get_record":
        return _get_record(params["record_id"])
    else:
        return _response(404, {"error": "Not found"})
```

- [ ] **Step 4: Run all query-api tests**

```bash
cd lambda/query-api && python -m pytest test_query_builder.py test_handler.py -v
```
Expected: All 16 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lambda/query-api/handler.py lambda/query-api/test_handler.py
git commit -m "feat: add query API Lambda handler with Athena integration"
```

---

## Task 7: CloudFormation Stack 07 — Audit UI

**Files:**
- Create: `cfn/07-audit-ui.yaml`

This stack creates: Cognito User Pool + App Client, API Gateway REST API + Cognito Authorizer, Query Lambda, SPA S3 bucket, CloudFront Distribution with OAC.

- [ ] **Step 1: Create 07-audit-ui.yaml**

Create `cfn/07-audit-ui.yaml`:

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: "Audit UI - Cognito, API Gateway, Query Lambda, SPA (S3 + CloudFront)"

Parameters:
  ProjectName:
    Type: String
    Default: litellm-gw
  CallbackUrl:
    Type: String
    Default: "https://localhost:3000"
    Description: "SPA callback URL (update after CloudFront is created)"

Resources:
  # --- Cognito User Pool ---
  AuditUserPool:
    Type: AWS::Cognito::UserPool
    Properties:
      UserPoolName: !Sub "${ProjectName}-audit-userpool"
      AdminCreateUserConfig:
        AllowAdminCreateUserOnly: true
      AutoVerifiedAttributes:
        - email
      UsernameAttributes:
        - email
      Policies:
        PasswordPolicy:
          MinimumLength: 8
          RequireUppercase: true
          RequireLowercase: true
          RequireNumbers: true
          RequireSymbols: true
      Schema:
        - Name: email
          Required: true
          Mutable: true

  AuditUserPoolDomain:
    Type: AWS::Cognito::UserPoolDomain
    Properties:
      Domain: !Sub "${ProjectName}-audit-${AWS::AccountId}"
      UserPoolId: !Ref AuditUserPool

  AuditUserPoolClient:
    Type: AWS::Cognito::UserPoolClient
    Properties:
      ClientName: !Sub "${ProjectName}-audit-spa"
      UserPoolId: !Ref AuditUserPool
      GenerateSecret: false
      ExplicitAuthFlows:
        - ALLOW_REFRESH_TOKEN_AUTH
      SupportedIdentityProviders:
        - COGNITO
      AllowedOAuthFlows:
        - code
      AllowedOAuthFlowsUserPoolClient: true
      AllowedOAuthScopes:
        - openid
        - email
        - profile
      CallbackURLs:
        - !Ref CallbackUrl
      LogoutURLs:
        - !Ref CallbackUrl
      AccessTokenValidity: 1
      RefreshTokenValidity: 30
      TokenValidityUnits:
        AccessToken: hours
        RefreshToken: days

  # --- Query Lambda Role ---
  QueryLambdaRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub "${ProjectName}-query-api-role"
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: AthenaQuery
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Effect: Allow
                Action:
                  - athena:StartQueryExecution
                  - athena:GetQueryExecution
                  - athena:GetQueryResults
                  - athena:StopQueryExecution
                Resource: "*"
              - Effect: Allow
                Action:
                  - s3:GetObject
                  - s3:PutObject
                  - s3:GetBucketLocation
                  - s3:ListBucket
                Resource:
                  - Fn::ImportValue: !Sub "${ProjectName}-AuditBucketArn"
                  - !Sub
                    - "${BucketArn}/*"
                    - BucketArn:
                        Fn::ImportValue: !Sub "${ProjectName}-AuditBucketArn"
              - Effect: Allow
                Action:
                  - glue:GetTable
                  - glue:GetDatabase
                  - glue:GetPartitions
                Resource: "*"

  # --- Query Lambda ---
  QueryLambdaFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Sub "${ProjectName}-query-api"
      Runtime: python3.12
      Handler: handler.handler
      MemorySize: 256
      Timeout: 30
      Role: !GetAtt QueryLambdaRole.Arn
      Code:
        S3Bucket:
          Fn::ImportValue: !Sub "${ProjectName}-ConfigBucketName"
        S3Key: lambda/query-api.zip
      Environment:
        Variables:
          ATHENA_DATABASE:
            Fn::ImportValue: !Sub "${ProjectName}-AuditGlueDatabaseName"
          ATHENA_TABLE: audit_logs
          ATHENA_WORKGROUP:
            Fn::ImportValue: !Sub "${ProjectName}-AuditAthenaWorkgroupName"
          S3_OUTPUT_LOCATION: !Sub
            - "s3://${BucketName}/athena-results/"
            - BucketName:
                Fn::ImportValue: !Sub "${ProjectName}-AuditBucketName"

  QueryLambdaPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref QueryLambdaFunction
      Action: lambda:InvokeFunction
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${AuditApi}/*"

  # --- API Gateway ---
  AuditApi:
    Type: AWS::ApiGateway::RestApi
    Properties:
      Name: !Sub "${ProjectName}-audit-api"
      Description: "Audit Log Query API"

  AuditApiAuthorizer:
    Type: AWS::ApiGateway::Authorizer
    Properties:
      Name: CognitoAuthorizer
      RestApiId: !Ref AuditApi
      Type: COGNITO_USER_POOLS
      IdentitySource: method.request.header.Authorization
      ProviderARNs:
        - !GetAtt AuditUserPool.Arn

  ApiResource:
    Type: AWS::ApiGateway::Resource
    Properties:
      RestApiId: !Ref AuditApi
      ParentId: !GetAtt AuditApi.RootResourceId
      PathPart: api

  ApiProxyResource:
    Type: AWS::ApiGateway::Resource
    Properties:
      RestApiId: !Ref AuditApi
      ParentId: !Ref ApiResource
      PathPart: "{proxy+}"

  ApiQueryResource:
    Type: AWS::ApiGateway::Resource
    Properties:
      RestApiId: !Ref AuditApi
      ParentId: !Ref ApiResource
      PathPart: query

  ApiQueryMethod:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId: !Ref AuditApi
      ResourceId: !Ref ApiQueryResource
      HttpMethod: POST
      AuthorizationType: COGNITO_USER_POOLS
      AuthorizerId: !Ref AuditApiAuthorizer
      Integration:
        Type: AWS_PROXY
        IntegrationHttpMethod: POST
        Uri: !Sub "arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${QueryLambdaFunction.Arn}/invocations"

  ApiProxyMethod:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId: !Ref AuditApi
      ResourceId: !Ref ApiProxyResource
      HttpMethod: GET
      AuthorizationType: COGNITO_USER_POOLS
      AuthorizerId: !Ref AuditApiAuthorizer
      Integration:
        Type: AWS_PROXY
        IntegrationHttpMethod: POST
        Uri: !Sub "arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${QueryLambdaFunction.Arn}/invocations"

  ApiOptionsMethod:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId: !Ref AuditApi
      ResourceId: !Ref ApiProxyResource
      HttpMethod: OPTIONS
      AuthorizationType: NONE
      Integration:
        Type: MOCK
        RequestTemplates:
          application/json: '{"statusCode": 200}'
        IntegrationResponses:
          - StatusCode: "200"
            ResponseParameters:
              method.response.header.Access-Control-Allow-Origin: "'*'"
              method.response.header.Access-Control-Allow-Headers: "'Content-Type,Authorization'"
              method.response.header.Access-Control-Allow-Methods: "'GET,POST,OPTIONS'"
      MethodResponses:
        - StatusCode: "200"
          ResponseParameters:
            method.response.header.Access-Control-Allow-Origin: true
            method.response.header.Access-Control-Allow-Headers: true
            method.response.header.Access-Control-Allow-Methods: true

  ApiDeployment:
    Type: AWS::ApiGateway::Deployment
    DependsOn:
      - ApiQueryResource
      - ApiQueryMethod
      - ApiProxyMethod
      - ApiOptionsMethod
    Properties:
      RestApiId: !Ref AuditApi

  ApiStage:
    Type: AWS::ApiGateway::Stage
    Properties:
      RestApiId: !Ref AuditApi
      DeploymentId: !Ref ApiDeployment
      StageName: prod

  # --- SPA S3 Bucket ---
  SpaBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${ProjectName}-audit-ui-${AWS::AccountId}"
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault:
              SSEAlgorithm: AES256
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true

  SpaBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref SpaBucket
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: AllowCloudFrontOAC
            Effect: Allow
            Principal:
              Service: cloudfront.amazonaws.com
            Action: s3:GetObject
            Resource: !Sub "${SpaBucket.Arn}/*"
            Condition:
              StringEquals:
                "AWS:SourceArn": !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${SpaCloudFront}"

  # --- CloudFront for SPA ---
  SpaOAC:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: !Sub "${ProjectName}-audit-spa-oac"
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  SpaCloudFront:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Enabled: true
        DefaultRootObject: index.html
        Origins:
          - Id: S3Origin
            DomainName: !GetAtt SpaBucket.RegionalDomainName
            OriginAccessControlId: !Ref SpaOAC
            S3OriginConfig:
              OriginAccessIdentity: ""
        DefaultCacheBehavior:
          TargetOriginId: S3Origin
          ViewerProtocolPolicy: redirect-to-https
          AllowedMethods:
            - GET
            - HEAD
          CachedMethods:
            - GET
            - HEAD
          CachePolicyId: 658327ea-f89d-4fab-a63d-7e88639e58f6
          Compress: true
        CustomErrorResponses:
          - ErrorCode: 403
            ResponseCode: 200
            ResponsePagePath: /index.html
          - ErrorCode: 404
            ResponseCode: 200
            ResponsePagePath: /index.html

Outputs:
  CognitoUserPoolId:
    Value: !Ref AuditUserPool
    Export:
      Name: !Sub "${ProjectName}-AuditUserPoolId"
  CognitoClientId:
    Value: !Ref AuditUserPoolClient
    Export:
      Name: !Sub "${ProjectName}-AuditClientId"
  CognitoDomain:
    Value: !Sub "${ProjectName}-audit-${AWS::AccountId}.auth.${AWS::Region}.amazoncognito.com"
    Export:
      Name: !Sub "${ProjectName}-AuditCognitoDomain"
  ApiEndpoint:
    Value: !Sub "https://${AuditApi}.execute-api.${AWS::Region}.amazonaws.com/prod"
    Export:
      Name: !Sub "${ProjectName}-AuditApiEndpoint"
  SpaBucketName:
    Value: !Ref SpaBucket
    Export:
      Name: !Sub "${ProjectName}-AuditSpaBucketName"
  SpaCloudFrontDomain:
    Value: !GetAtt SpaCloudFront.DomainName
    Export:
      Name: !Sub "${ProjectName}-AuditSpaDomain"
  SpaCloudFrontDistributionId:
    Value: !Ref SpaCloudFront
    Export:
      Name: !Sub "${ProjectName}-AuditSpaDistributionId"
```

- [ ] **Step 2: Validate template**

```bash
aws cloudformation validate-template --template-body file://cfn/07-audit-ui.yaml --region us-east-1
```
Expected: Valid.

- [ ] **Step 3: Commit**

```bash
git add cfn/07-audit-ui.yaml
git commit -m "feat: add CloudFormation stack for audit UI (Cognito, API GW, SPA)"
```

---

## Task 8: React SPA — Project Setup & Auth

**Files:**
- Create: `audit-ui/` (full project scaffold)

- [ ] **Step 1: Initialize Vite React project**

```bash
cd /home/ec2-user/litellm-gw
npm create vite@latest audit-ui -- --template react
cd audit-ui
npm install
npm install -D tailwindcss @tailwindcss/vite
```

- [ ] **Step 2: Configure Tailwind CSS**

Replace `audit-ui/vite.config.js`:

```js
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
});
```

Replace `audit-ui/src/index.css`:

```css
@import "tailwindcss";
```

- [ ] **Step 3: Install Cognito auth library**

```bash
cd /home/ec2-user/litellm-gw/audit-ui
npm install amazon-cognito-identity-js
```

- [ ] **Step 4: Create config.js**

Create `audit-ui/src/config.js`:

```js
const config = {
  apiEndpoint: import.meta.env.VITE_API_ENDPOINT || "",
  cognito: {
    userPoolId: import.meta.env.VITE_COGNITO_USER_POOL_ID || "",
    clientId: import.meta.env.VITE_COGNITO_CLIENT_ID || "",
    domain: import.meta.env.VITE_COGNITO_DOMAIN || "",
  },
};

export default config;
```

- [ ] **Step 5: Create useAuth hook**

Create `audit-ui/src/hooks/useAuth.js`:

```js
import { useState, useEffect, useCallback } from "react";
import {
  CognitoUserPool,
  CognitoUser,
  AuthenticationDetails,
} from "amazon-cognito-identity-js";
import config from "../config";

const userPool = new CognitoUserPool({
  UserPoolId: config.cognito.userPoolId,
  ClientId: config.cognito.clientId,
});

export default function useAuth() {
  const [user, setUser] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const currentUser = userPool.getCurrentUser();
    if (currentUser) {
      currentUser.getSession((err, session) => {
        if (err || !session.isValid()) {
          setUser(null);
        } else {
          setUser({
            email: currentUser.getUsername(),
            token: session.getAccessToken().getJwtToken(),
            idToken: session.getIdToken().getJwtToken(),
          });
        }
        setLoading(false);
      });
    } else {
      setLoading(false);
    }
  }, []);

  const login = useCallback((email, password) => {
    return new Promise((resolve, reject) => {
      const cognitoUser = new CognitoUser({
        Username: email,
        Pool: userPool,
      });
      const authDetails = new AuthenticationDetails({
        Username: email,
        Password: password,
      });

      cognitoUser.authenticateUser(authDetails, {
        onSuccess: (session) => {
          const userData = {
            email,
            token: session.getAccessToken().getJwtToken(),
            idToken: session.getIdToken().getJwtToken(),
          };
          setUser(userData);
          setError(null);
          resolve(userData);
        },
        onFailure: (err) => {
          setError(err.message);
          reject(err);
        },
        newPasswordRequired: (userAttributes) => {
          resolve({ newPasswordRequired: true, cognitoUser, userAttributes });
        },
      });
    });
  }, []);

  const completeNewPassword = useCallback((cognitoUser, newPassword) => {
    return new Promise((resolve, reject) => {
      cognitoUser.completeNewPasswordChallenge(newPassword, {}, {
        onSuccess: (session) => {
          const userData = {
            email: cognitoUser.getUsername(),
            token: session.getAccessToken().getJwtToken(),
            idToken: session.getIdToken().getJwtToken(),
          };
          setUser(userData);
          resolve(userData);
        },
        onFailure: (err) => {
          setError(err.message);
          reject(err);
        },
      });
    });
  }, []);

  const logout = useCallback(() => {
    const currentUser = userPool.getCurrentUser();
    if (currentUser) currentUser.signOut();
    setUser(null);
  }, []);

  const getToken = useCallback(() => {
    return new Promise((resolve) => {
      const currentUser = userPool.getCurrentUser();
      if (!currentUser) return resolve(null);
      currentUser.getSession((err, session) => {
        if (err || !session.isValid()) return resolve(null);
        resolve(session.getAccessToken().getJwtToken());
      });
    });
  }, []);

  return { user, loading, error, login, logout, getToken, completeNewPassword };
}
```

- [ ] **Step 6: Create useAuditQuery hook**

Create `audit-ui/src/hooks/useAuditQuery.js`:

```js
import { useState, useCallback, useRef } from "react";
import config from "../config";

export default function useAuditQuery(getToken) {
  const [results, setResults] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [queryInfo, setQueryInfo] = useState(null);
  const pollingRef = useRef(null);

  const apiCall = useCallback(
    async (path, options = {}) => {
      const token = await getToken();
      const res = await fetch(`${config.apiEndpoint}${path}`, {
        ...options,
        headers: {
          "Content-Type": "application/json",
          Authorization: token,
          ...options.headers,
        },
      });
      if (!res.ok) throw new Error(`API error: ${res.status}`);
      return res.json();
    },
    [getToken]
  );

  const search = useCallback(
    async (filters) => {
      setLoading(true);
      setError(null);
      setResults([]);

      try {
        const { execution_id } = await apiCall("/api/query", {
          method: "POST",
          body: JSON.stringify(filters),
        });

        const poll = async () => {
          const data = await apiCall(`/api/query/${execution_id}`);
          if (data.status === "SUCCEEDED") {
            setResults(data.results || []);
            setQueryInfo({ count: data.count });
            setLoading(false);
          } else if (data.status === "FAILED") {
            setError(data.error || "Query failed");
            setLoading(false);
          } else {
            pollingRef.current = setTimeout(poll, 1000);
          }
        };
        await poll();
      } catch (err) {
        setError(err.message);
        setLoading(false);
      }
    },
    [apiCall]
  );

  const fetchRecord = useCallback(
    async (recordId) => {
      const data = await apiCall(`/api/record/${recordId}`);
      return data.record;
    },
    [apiCall]
  );

  return { results, loading, error, queryInfo, search, fetchRecord };
}
```

- [ ] **Step 7: Commit**

```bash
cd /home/ec2-user/litellm-gw
git add audit-ui/package.json audit-ui/package-lock.json audit-ui/vite.config.js audit-ui/src/index.css audit-ui/src/config.js audit-ui/src/hooks/useAuth.js audit-ui/src/hooks/useAuditQuery.js
git commit -m "feat: scaffold audit UI with Vite, Tailwind, Cognito auth hooks"
```

---

## Task 9: React SPA — UI Components

**Files:**
- Create: `audit-ui/src/App.jsx`
- Create: `audit-ui/src/components/Layout.jsx`
- Create: `audit-ui/src/components/FilterBar.jsx`
- Create: `audit-ui/src/components/ResultsTable.jsx`
- Create: `audit-ui/src/components/DetailPanel.jsx`
- Create: `audit-ui/src/components/Pagination.jsx`
- Modify: `audit-ui/src/main.jsx`

- [ ] **Step 1: Create Layout component**

Create `audit-ui/src/components/Layout.jsx`:

```jsx
export default function Layout({ user, onLogout, children }) {
  return (
    <div className="min-h-screen bg-gray-50">
      <nav className="bg-gray-900 text-white px-5 py-3 flex justify-between items-center">
        <span className="font-bold text-lg">LiteLLM Audit Logs</span>
        <div className="text-sm text-gray-400">
          {user?.email}
          <button
            onClick={onLogout}
            className="ml-4 text-gray-300 hover:text-white"
          >
            Logout
          </button>
        </div>
      </nav>
      {children}
    </div>
  );
}
```

- [ ] **Step 2: Create FilterBar component**

Create `audit-ui/src/components/FilterBar.jsx`:

```jsx
import { useState } from "react";

const today = new Date().toISOString().slice(0, 10);
const weekAgo = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);

const MODELS = [
  "All Models",
  "us.anthropic.claude-opus-4-6-v1",
  "us.anthropic.claude-sonnet-4-6",
  "us.anthropic.claude-haiku-4-5-20251001-v1:0",
];
const CALL_TYPES = ["All Types", "anthropic_messages", "acompletion", "aembedding"];
const FINISH_REASONS = ["All", "stop", "max_tokens", "tool_use"];

export default function FilterBar({ onSearch, loading }) {
  const [filters, setFilters] = useState({
    start_date: weekAgo,
    end_date: today,
    model: "",
    call_type: "",
    session_id: "",
    finish_reason: "",
    device_id: "",
    source_ip: "",
    min_total_tokens: "",
    has_tool_calls: false,
    keyword: "",
  });

  const update = (key, value) =>
    setFilters((prev) => ({ ...prev, [key]: value }));

  const handleSearch = () => {
    const params = { start_date: filters.start_date, end_date: filters.end_date };
    if (filters.model) params.model = filters.model;
    if (filters.call_type) params.call_type = filters.call_type;
    if (filters.session_id) params.session_id = filters.session_id;
    if (filters.finish_reason) params.finish_reason = filters.finish_reason;
    if (filters.device_id) params.device_id = filters.device_id;
    if (filters.source_ip) params.source_ip = filters.source_ip;
    if (filters.min_total_tokens) params.min_total_tokens = parseInt(filters.min_total_tokens, 10);
    if (filters.has_tool_calls) params.has_tool_calls = true;
    if (filters.keyword) params.keyword = filters.keyword;
    onSearch(params);
  };

  const inputCls = "border border-gray-300 rounded px-2 py-1.5 text-sm";
  const labelCls = "text-xs text-gray-500 uppercase mb-1";

  return (
    <div className="bg-white border-b border-gray-200 px-5 py-4">
      <div className="flex flex-wrap gap-3 items-end">
        <div>
          <div className={labelCls}>Start Date</div>
          <input type="date" className={inputCls} value={filters.start_date} onChange={(e) => update("start_date", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>End Date</div>
          <input type="date" className={inputCls} value={filters.end_date} onChange={(e) => update("end_date", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Model</div>
          <select className={inputCls + " min-w-[180px]"} value={filters.model} onChange={(e) => update("model", e.target.value)}>
            {MODELS.map((m) => (
              <option key={m} value={m === "All Models" ? "" : m}>{m}</option>
            ))}
          </select>
        </div>
        <div>
          <div className={labelCls}>Call Type</div>
          <select className={inputCls + " min-w-[140px]"} value={filters.call_type} onChange={(e) => update("call_type", e.target.value)}>
            {CALL_TYPES.map((t) => (
              <option key={t} value={t === "All Types" ? "" : t}>{t}</option>
            ))}
          </select>
        </div>
        <div>
          <div className={labelCls}>Finish Reason</div>
          <select className={inputCls} value={filters.finish_reason} onChange={(e) => update("finish_reason", e.target.value)}>
            {FINISH_REASONS.map((r) => (
              <option key={r} value={r === "All" ? "" : r}>{r}</option>
            ))}
          </select>
        </div>
        <button onClick={handleSearch} disabled={loading} className="bg-blue-600 text-white px-5 py-1.5 rounded text-sm font-semibold hover:bg-blue-700 disabled:opacity-50">
          {loading ? "Searching..." : "Search"}
        </button>
      </div>
      <div className="flex flex-wrap gap-3 items-end mt-3 pt-3 border-t border-dashed border-gray-200">
        <div>
          <div className={labelCls}>Session ID</div>
          <input className={inputCls + " w-48"} placeholder="f61cee15-..." value={filters.session_id} onChange={(e) => update("session_id", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Device ID</div>
          <input className={inputCls + " w-48"} placeholder="8d6ae821..." value={filters.device_id} onChange={(e) => update("device_id", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Source IP</div>
          <input className={inputCls + " w-36"} placeholder="44.219.177.250" value={filters.source_ip} onChange={(e) => update("source_ip", e.target.value)} />
        </div>
        <div>
          <div className={labelCls}>Min Tokens</div>
          <input type="number" className={inputCls + " w-24"} placeholder="1000" value={filters.min_total_tokens} onChange={(e) => update("min_total_tokens", e.target.value)} />
        </div>
        <label className="flex items-center gap-1.5 pb-0.5">
          <input type="checkbox" checked={filters.has_tool_calls} onChange={(e) => update("has_tool_calls", e.target.checked)} />
          <span className="text-sm text-gray-600">Has Tool Calls</span>
        </label>
        <div>
          <div className={labelCls}>Keyword</div>
          <input className={inputCls + " w-40"} placeholder="Search previews..." value={filters.keyword} onChange={(e) => update("keyword", e.target.value)} />
        </div>
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Create ResultsTable component**

Create `audit-ui/src/components/ResultsTable.jsx`:

```jsx
const MODEL_COLORS = {
  opus: "bg-pink-100 text-pink-800",
  sonnet: "bg-purple-100 text-purple-800",
  haiku: "bg-sky-100 text-sky-800",
  gpt: "bg-green-100 text-green-800",
  gemini: "bg-amber-100 text-amber-800",
};

function modelBadge(model) {
  const key = Object.keys(MODEL_COLORS).find((k) => model?.toLowerCase().includes(k));
  const color = MODEL_COLORS[key] || "bg-gray-100 text-gray-800";
  const label = model?.split(".").pop()?.split("-v")[0] || model;
  return <span className={`${color} px-2 py-0.5 rounded-full text-xs`}>{label}</span>;
}

function toolBadges(toolNamesStr) {
  if (!toolNamesStr) return <span className="text-gray-400">—</span>;
  try {
    const names = JSON.parse(toolNamesStr.replace(/'/g, '"'));
    return names.map((name) => (
      <span key={name} className="bg-green-50 text-green-800 px-1.5 py-0.5 rounded text-xs mr-1">{name}</span>
    ));
  } catch {
    return <span className="text-gray-400">—</span>;
  }
}

export default function ResultsTable({ results, onSelectRow, selectedId }) {
  if (!results.length) {
    return <div className="p-10 text-center text-gray-400">No results. Adjust filters and search.</div>;
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="bg-white border-b-2 border-gray-200 text-gray-500 font-semibold">
            <th className="px-3 py-2.5 text-left">Time</th>
            <th className="px-2 py-2.5 text-left">Model</th>
            <th className="px-2 py-2.5 text-left">Type</th>
            <th className="px-2 py-2.5 text-left">Finish</th>
            <th className="px-2 py-2.5 text-right">Tokens</th>
            <th className="px-2 py-2.5 text-left">Tools</th>
            <th className="px-2 py-2.5 text-left">User Message</th>
          </tr>
        </thead>
        <tbody>
          {results.map((row, i) => {
            const isFailed = row.finish_reason === "max_tokens" || row.finish_reason === "error";
            return (
              <tr
                key={row.id || i}
                onClick={() => onSelectRow(row)}
                className={`border-b border-gray-100 cursor-pointer hover:bg-blue-50 ${
                  selectedId === row.id ? "bg-blue-50" : isFailed ? "bg-red-50" : i % 2 ? "bg-gray-50" : "bg-white"
                }`}
              >
                <td className="px-3 py-2.5 whitespace-nowrap text-blue-600">{row.start_time?.slice(0, 19)}</td>
                <td className="px-2 py-2.5">{modelBadge(row.model)}</td>
                <td className="px-2 py-2.5 text-gray-600">{row.call_type}</td>
                <td className="px-2 py-2.5">
                  <span className={row.finish_reason === "stop" ? "text-green-600" : "text-red-600"}>
                    {row.finish_reason}
                  </span>
                </td>
                <td className="px-2 py-2.5 text-right font-mono">{Number(row.total_tokens || 0).toLocaleString()}</td>
                <td className="px-2 py-2.5">{toolBadges(row.tool_names)}</td>
                <td className="px-2 py-2.5 text-gray-700 max-w-xs truncate">{row.user_message_preview}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
```

- [ ] **Step 4: Create DetailPanel component**

Create `audit-ui/src/components/DetailPanel.jsx`:

```jsx
import { useState, useEffect } from "react";

function InfoCard({ label, value, mono }) {
  return (
    <div className="bg-white p-3 rounded-lg border border-gray-200">
      <div className="text-xs text-gray-400 uppercase">{label}</div>
      <div className={`font-semibold mt-1 ${mono ? "font-mono text-xs" : ""}`}>{value || "—"}</div>
    </div>
  );
}

const TABS = ["User Message", "Response", "Raw Request", "Raw Response"];

export default function DetailPanel({ row, fetchRecord, onClose }) {
  const [activeTab, setActiveTab] = useState(0);
  const [fullRecord, setFullRecord] = useState(null);

  useEffect(() => {
    if (row?.id && fetchRecord) {
      fetchRecord(row.id).then(setFullRecord).catch(() => setFullRecord(null));
    }
  }, [row?.id, fetchRecord]);

  if (!row) return null;

  const cachedPct = row.prompt_tokens > 0
    ? ((Number(row.cached_tokens) / Number(row.prompt_tokens)) * 100).toFixed(1)
    : "0";

  const tabContent = () => {
    if (activeTab === 0) return row.user_message_preview || "(empty)";
    if (activeTab === 1) return row.response_preview || "(empty)";
    if (activeTab === 2) return fullRecord?.raw_messages || "Loading...";
    if (activeTab === 3) return fullRecord?.raw_response || "Loading...";
  };

  return (
    <div className="bg-gray-100 border-t border-gray-300 p-5">
      <div className="flex justify-between items-center mb-4">
        <div>
          <span className="text-lg font-bold">Request Detail</span>
          <span className="ml-3 text-xs text-gray-400 font-mono">{row.id}</span>
        </div>
        <button onClick={onClose} className="border border-gray-300 rounded px-3 py-1 text-sm hover:bg-white">Close</button>
      </div>

      <div className="grid grid-cols-3 gap-3 mb-5">
        <InfoCard label="Model" value={row.model} />
        <InfoCard label="Time" value={row.start_time?.slice(0, 19)} />
        <InfoCard label="Call Type" value={row.call_type} />
        <InfoCard label="Tokens (In / Out / Total)" value={`${Number(row.prompt_tokens).toLocaleString()} / ${Number(row.completion_tokens).toLocaleString()} / ${Number(row.total_tokens).toLocaleString()}`} mono />
        <InfoCard label="Cached Tokens" value={`${Number(row.cached_tokens).toLocaleString()} (${cachedPct}%)`} mono />
        <InfoCard label="Finish Reason" value={row.finish_reason} />
        <InfoCard label="Session ID" value={row.session_id} mono />
        <InfoCard label="Device ID" value={row.device_id} mono />
        <InfoCard label="Source IP" value={row.source_ip} mono />
      </div>

      <div className="flex border-b-2 border-gray-200 mb-4">
        {TABS.map((tab, i) => (
          <button
            key={tab}
            onClick={() => setActiveTab(i)}
            className={`px-4 py-2 text-sm ${
              activeTab === i ? "border-b-2 border-blue-600 text-blue-600 font-semibold -mb-0.5" : "text-gray-500"
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      <pre className="bg-gray-800 text-gray-200 p-4 rounded-lg text-xs font-mono leading-relaxed max-h-64 overflow-auto whitespace-pre-wrap">
        {tabContent()}
      </pre>
    </div>
  );
}
```

- [ ] **Step 5: Create Pagination component**

Create `audit-ui/src/components/Pagination.jsx`:

```jsx
export default function Pagination({ count }) {
  return (
    <div className="px-5 py-3 border-t border-gray-200 bg-white flex justify-between items-center text-sm text-gray-500">
      <span>{count ?? 0} results</span>
    </div>
  );
}
```

- [ ] **Step 6: Create App.jsx**

Replace `audit-ui/src/App.jsx`:

```jsx
import { useState } from "react";
import useAuth from "./hooks/useAuth";
import useAuditQuery from "./hooks/useAuditQuery";
import Layout from "./components/Layout";
import FilterBar from "./components/FilterBar";
import ResultsTable from "./components/ResultsTable";
import DetailPanel from "./components/DetailPanel";
import Pagination from "./components/Pagination";

function LoginPage({ onLogin, error }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [newPw, setNewPw] = useState("");
  const [challenge, setChallenge] = useState(null);

  const handleSubmit = async (e) => {
    e.preventDefault();
    const result = await onLogin(email, password);
    if (result?.newPasswordRequired) {
      setChallenge(result);
    }
  };

  if (challenge) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-100">
        <form onSubmit={(e) => { e.preventDefault(); challenge.completeNewPassword(challenge.cognitoUser, newPw); }} className="bg-white p-8 rounded-lg shadow-md w-96">
          <h2 className="text-xl font-bold mb-4">Set New Password</h2>
          <input type="password" placeholder="New Password" value={newPw} onChange={(e) => setNewPw(e.target.value)} className="w-full border rounded px-3 py-2 mb-4" />
          <button type="submit" className="w-full bg-blue-600 text-white py-2 rounded font-semibold">Confirm</button>
        </form>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-100">
      <form onSubmit={handleSubmit} className="bg-white p-8 rounded-lg shadow-md w-96">
        <h2 className="text-xl font-bold mb-6">LiteLLM Audit Logs</h2>
        {error && <div className="bg-red-50 text-red-600 p-2 rounded mb-4 text-sm">{error}</div>}
        <input type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full border rounded px-3 py-2 mb-3" />
        <input type="password" placeholder="Password" value={password} onChange={(e) => setPassword(e.target.value)} className="w-full border rounded px-3 py-2 mb-4" />
        <button type="submit" className="w-full bg-blue-600 text-white py-2 rounded font-semibold hover:bg-blue-700">Sign In</button>
      </form>
    </div>
  );
}

export default function App() {
  const { user, loading: authLoading, error: authError, login, logout, getToken, completeNewPassword } = useAuth();
  const { results, loading, error, queryInfo, search, fetchRecord } = useAuditQuery(getToken);
  const [selectedRow, setSelectedRow] = useState(null);

  if (authLoading) {
    return <div className="min-h-screen flex items-center justify-center text-gray-400">Loading...</div>;
  }

  if (!user) {
    return <LoginPage onLogin={login} error={authError} completeNewPassword={completeNewPassword} />;
  }

  return (
    <Layout user={user} onLogout={logout}>
      <FilterBar onSearch={search} loading={loading} />
      {error && <div className="bg-red-50 text-red-600 px-5 py-2 text-sm">{error}</div>}
      <ResultsTable results={results} onSelectRow={setSelectedRow} selectedId={selectedRow?.id} />
      {selectedRow && <DetailPanel row={selectedRow} fetchRecord={fetchRecord} onClose={() => setSelectedRow(null)} />}
      <Pagination count={queryInfo?.count} />
    </Layout>
  );
}
```

- [ ] **Step 7: Update main.jsx**

Replace `audit-ui/src/main.jsx`:

```jsx
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import App from "./App";

createRoot(document.getElementById("root")).render(
  <StrictMode>
    <App />
  </StrictMode>
);
```

- [ ] **Step 8: Verify build succeeds**

```bash
cd /home/ec2-user/litellm-gw/audit-ui && npm run build
```
Expected: Build succeeds, `dist/` directory created.

- [ ] **Step 9: Commit**

```bash
cd /home/ec2-user/litellm-gw
git add audit-ui/src/
git commit -m "feat: add audit log query UI components (filter, table, detail panel)"
```

---

## Task 10: Update Deploy Script & .gitignore

**Files:**
- Modify: `deploy.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Update .gitignore**

Append to `.gitignore`:

```
.claude/
.superpowers/
audit-ui/node_modules/
audit-ui/dist/
```

- [ ] **Step 2: Add Lambda packaging and stack 06/07 deployment to deploy.sh**

Append the following after the existing Step 6 (CloudFront stack, around line 108) in `deploy.sh`:

```bash
# Step 7: Package and upload Lambda functions
log "Step 7: Packaging Lambda functions..."

# Stream Processor Lambda
cd lambda/stream-processor
zip -r /tmp/stream-processor.zip handler.py parser.py
aws s3 cp /tmp/stream-processor.zip "s3://${PROJECT_NAME}-config-$(aws sts get-caller-identity --query Account --output text)/lambda/stream-processor.zip" --region "$REGION"
cd "$SCRIPT_DIR"

# Query API Lambda
cd lambda/query-api
zip -r /tmp/query-api.zip handler.py query_builder.py
aws s3 cp /tmp/query-api.zip "s3://${PROJECT_NAME}-config-$(aws sts get-caller-identity --query Account --output text)/lambda/query-api.zip" --region "$REGION"
cd "$SCRIPT_DIR"

log "Lambda packages uploaded to S3"

# Step 8: Deploy Audit Pipeline stack
log "Step 8: Deploying Audit Pipeline stack..."
deploy_stack "${PROJECT_NAME}-audit-pipeline" "cfn/06-audit-pipeline.yaml" \
  "ProjectName=${PROJECT_NAME}"
wait_stack "${PROJECT_NAME}-audit-pipeline"

# Step 9: Deploy Audit UI stack
log "Step 9: Deploying Audit UI stack..."
deploy_stack "${PROJECT_NAME}-audit-ui" "cfn/07-audit-ui.yaml" \
  "ProjectName=${PROJECT_NAME}"
wait_stack "${PROJECT_NAME}-audit-ui"

# Step 10: Build and deploy SPA
log "Step 10: Building and deploying Audit UI SPA..."

AUDIT_API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' --output text)
COGNITO_POOL_ID=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoUserPoolId`].OutputValue' --output text)
COGNITO_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoClientId`].OutputValue' --output text)
COGNITO_DOMAIN=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoDomain`].OutputValue' --output text)
SPA_BUCKET=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaBucketName`].OutputValue' --output text)
SPA_CF_ID=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDistributionId`].OutputValue' --output text)

cd audit-ui
VITE_API_ENDPOINT="$AUDIT_API_ENDPOINT" \
VITE_COGNITO_USER_POOL_ID="$COGNITO_POOL_ID" \
VITE_COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN" \
npm run build

aws s3 sync dist/ "s3://${SPA_BUCKET}/" --delete --region "$REGION"
aws cloudfront create-invalidation --distribution-id "$SPA_CF_ID" --paths "/*" --region "$REGION"
cd "$SCRIPT_DIR"

SPA_DOMAIN=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDomain`].OutputValue' --output text)

log ""
log "========================================="
log "Audit UI Deployment Complete"
log "========================================="
log "Audit UI:     https://${SPA_DOMAIN}"
log "API Endpoint: ${AUDIT_API_ENDPOINT}"
log "Cognito Pool: ${COGNITO_POOL_ID}"
log ""
log "Next: Create admin user:"
log "  aws cognito-idp admin-create-user \\"
log "    --user-pool-id ${COGNITO_POOL_ID} \\"
log "    --username admin@example.com \\"
log "    --temporary-password 'TempPass123!' \\"
log "    --user-attributes Name=email,Value=admin@example.com Name=email_verified,Value=true \\"
log "    --region ${REGION}"
log ""
log "Then update Cognito callback URL to https://${SPA_DOMAIN}:"
log "  aws cognito-idp update-user-pool-client \\"
log "    --user-pool-id ${COGNITO_POOL_ID} \\"
log "    --client-id ${COGNITO_CLIENT_ID} \\"
log "    --callback-urls https://${SPA_DOMAIN} \\"
log "    --logout-urls https://${SPA_DOMAIN} \\"
log "    --region ${REGION}"
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore deploy.sh
git commit -m "feat: add Lambda packaging and audit stack deployment to deploy.sh"
```

---

## Task 11: End-to-End Deployment Verification

**Files:** None (deployment + manual testing)

- [ ] **Step 1: Deploy the updated data stack (enable DynamoDB Streams)**

```bash
aws cloudformation update-stack \
  --stack-name litellm-gw-data \
  --template-body file://cfn/03-data.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=litellm-gw \
  --region us-east-1
```

Wait for completion:
```bash
aws cloudformation wait stack-update-complete --stack-name litellm-gw-data --region us-east-1
```

- [ ] **Step 2: Verify DynamoDB Streams is enabled**

```bash
aws dynamodb describe-table --table-name litellm-gw-audit-log --region us-east-1 \
  --query 'Table.StreamSpecification'
```
Expected: `{"StreamEnabled": true, "StreamViewType": "NEW_IMAGE"}`

- [ ] **Step 3: Package and upload Lambda functions**

```bash
cd lambda/stream-processor && zip -r /tmp/stream-processor.zip handler.py parser.py && cd -
cd lambda/query-api && zip -r /tmp/query-api.zip handler.py query_builder.py && cd -
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp /tmp/stream-processor.zip "s3://litellm-gw-config-${ACCOUNT_ID}/lambda/stream-processor.zip" --region us-east-1
aws s3 cp /tmp/query-api.zip "s3://litellm-gw-config-${ACCOUNT_ID}/lambda/query-api.zip" --region us-east-1
```

- [ ] **Step 4: Deploy stack 06 (audit pipeline)**

```bash
aws cloudformation create-stack \
  --stack-name litellm-gw-audit-pipeline \
  --template-body file://cfn/06-audit-pipeline.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=litellm-gw \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
aws cloudformation wait stack-create-complete --stack-name litellm-gw-audit-pipeline --region us-east-1
```

- [ ] **Step 5: Trigger a test API call and verify S3 data**

```bash
# Make a test call to LiteLLM
curl -s https://d2cyolr4rt91j1.cloudfront.net/v1/chat/completions \
  -H "Authorization: Bearer $(aws secretsmanager get-secret-value --secret-id litellm/default/master-key --query SecretString --output text --region us-east-1)" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-haiku","messages":[{"role":"user","content":"ping"}],"max_tokens":5}'

# Wait for Stream processing (up to 60s batching window)
sleep 70

# Check S3 for audit records
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 ls "s3://litellm-gw-audit-${ACCOUNT_ID}/logs/" --recursive --region us-east-1
```
Expected: At least one `.json` file in the `logs/year=2026/month=04/day=20/` path.

- [ ] **Step 6: Verify Athena can query the data**

```bash
aws athena start-query-execution \
  --query-string "SELECT id, model, start_time, total_tokens FROM litellm_gw_audit.audit_logs LIMIT 5" \
  --work-group litellm-gw-audit \
  --region us-east-1
```

Wait and fetch results:
```bash
# Use the QueryExecutionId from the previous command
EXEC_ID="<execution-id-from-above>"
aws athena get-query-execution --query-execution-id "$EXEC_ID" --region us-east-1 --query 'QueryExecution.Status.State'
aws athena get-query-results --query-execution-id "$EXEC_ID" --region us-east-1
```
Expected: Query returns rows with audit log records.

- [ ] **Step 7: Deploy stack 07 (audit UI)**

```bash
aws cloudformation create-stack \
  --stack-name litellm-gw-audit-ui \
  --template-body file://cfn/07-audit-ui.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=litellm-gw \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
aws cloudformation wait stack-create-complete --stack-name litellm-gw-audit-ui --region us-east-1
```

- [ ] **Step 8: Build and deploy SPA**

```bash
# Get stack outputs
API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' --output text)
POOL_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`CognitoUserPoolId`].OutputValue' --output text)
CLIENT_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`CognitoClientId`].OutputValue' --output text)
SPA_BUCKET=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`SpaBucketName`].OutputValue' --output text)
SPA_CF_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDistributionId`].OutputValue' --output text)
SPA_DOMAIN=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDomain`].OutputValue' --output text)

# Build with env vars
cd audit-ui
VITE_API_ENDPOINT="$API_ENDPOINT" VITE_COGNITO_USER_POOL_ID="$POOL_ID" VITE_COGNITO_CLIENT_ID="$CLIENT_ID" npm run build

# Upload to S3 and invalidate cache
aws s3 sync dist/ "s3://${SPA_BUCKET}/" --delete --region us-east-1
aws cloudfront create-invalidation --distribution-id "$SPA_CF_ID" --paths "/*" --region us-east-1
cd ..
```

- [ ] **Step 9: Create admin user and update callback URL**

```bash
# Create admin user
aws cognito-idp admin-create-user \
  --user-pool-id "$POOL_ID" \
  --username admin@example.com \
  --temporary-password 'TempPass123!' \
  --user-attributes Name=email,Value=admin@example.com Name=email_verified,Value=true \
  --region us-east-1

# Update callback URL to actual CloudFront domain
aws cognito-idp update-user-pool-client \
  --user-pool-id "$POOL_ID" \
  --client-id "$CLIENT_ID" \
  --supported-identity-providers COGNITO \
  --allowed-o-auth-flows code \
  --allowed-o-auth-flows-user-pool-client \
  --allowed-o-auth-scopes openid email profile \
  --callback-urls "https://${SPA_DOMAIN}" \
  --logout-urls "https://${SPA_DOMAIN}" \
  --region us-east-1
```

- [ ] **Step 10: Verify the full flow**

1. Open `https://${SPA_DOMAIN}` in browser
2. Login with `admin@example.com` / `TempPass123!`
3. Set new password when prompted
4. Set date range and click Search
5. Verify audit log records appear in the table
6. Click a row to expand the detail panel

- [ ] **Step 11: Final commit**

```bash
git add -A
git commit -m "feat: complete audit log visualization system deployment"
```
