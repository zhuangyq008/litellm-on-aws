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
