import re
import ast
import json


def _extract_int(text: str, pattern: str, default: int = 0) -> int:
    match = re.search(pattern, text)
    if match:
        return int(match.group(1))
    return default


def parse_usage(usage_str: str) -> dict:
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


def parse_response(response_str: str) -> dict:
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


def _extract_user_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                texts.append(block.get("text", ""))
        return texts[-1] if texts else ""
    return ""


def parse_messages(messages_str: str) -> dict:
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


def parse_metadata(metadata_str: str) -> dict:
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


def _get_s(record: dict, key: str) -> str:
    return record.get(key, {}).get("S", "")


def transform_record(record: dict) -> dict:
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
