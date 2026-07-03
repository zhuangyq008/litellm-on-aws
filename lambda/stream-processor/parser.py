import re
import ast
import json
from typing import Any

PREVIEW_MAX_LENGTH = 500


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
        if len(preview) > PREVIEW_MAX_LENGTH:
            preview = preview[:PREVIEW_MAX_LENGTH]

        tool_names_in_functions = re.findall(r"Function\(arguments=.*?, name='(\w+)'\)", response_str, re.DOTALL)
        if tool_names_in_functions:
            tool_names = list(dict.fromkeys(tool_names_in_functions))
        else:
            tool_names = []

        has_tool_calls = bool(tool_names)

        return {
            "finish_reason": finish_reason,
            "response_preview": preview,
            "has_tool_calls": has_tool_calls,
            "tool_names": tool_names,
        }
    except Exception:
        return defaults


def _extract_user_text(content: Any) -> str:
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

        if len(last_user_text) > PREVIEW_MAX_LENGTH:
            last_user_text = last_user_text[:PREVIEW_MAX_LENGTH]

        return {
            "message_count": len(messages),
            "user_message_preview": last_user_text,
        }
    except Exception:
        return defaults


def parse_metadata(metadata_str: str) -> dict:
    defaults = {
        "device_id": "",
        "session_id": "",
        "source_ip": "",
        "key_hash": "",
        "key_alias": "",
        "team_id": "",
        "key_user_id": "",
    }
    if not metadata_str or not isinstance(metadata_str, str):
        return defaults

    # 用正则按字段抽取，不做整体 ast.literal_eval —— LiteLLM 的 metadata 含非字面量
    # 对象 repr(datetime/自定义类)，整体解析必失败。

    # source_ip：仅从 headers 块内取 x-forwarded-for（其本身即客户端来源）
    source_ip = ""
    hm = re.search(r"['\"]headers['\"]\s*:\s*\{([^}]*)\}", metadata_str)
    if hm:
        fwd = re.search(r"['\"]x-forwarded-for['\"]\s*:\s*['\"]([^'\"]*)['\"]", hm.group(1))
        if fwd:
            source_ip = fwd.group(1).split(",")[0].strip()

    # device/session：从 user_id 的内嵌 JSON 取
    device_id = ""
    session_id = ""
    uid = re.search(r"['\"]user_id['\"]\s*:\s*'(\{[^}]*\})'", metadata_str)
    if uid:
        try:
            user_id_obj = json.loads(uid.group(1))
            device_id = user_id_obj.get("device_id", "")
            session_id = user_id_obj.get("session_id", "")
        except (json.JSONDecodeError, AttributeError):
            pass

    # key 身份：user_api_key_* 是 LiteLLM 设的**顶层标量**。先剥掉最外层 {}，再反复
    # 抹掉所有嵌套 {..} 块(headers、user_id 内嵌 JSON 等一切用户可控内容)，防止攻击者
    # 用请求头/字段名伪造 'user_api_key_alias':'admin' 冒充归因(re.search 取首个匹配的注入漏洞)。
    masked = metadata_str.strip()
    if masked[:1] == "{" and masked[-1:] == "}":
        masked = masked[1:-1]
    prev = None
    while prev != masked and "{" in masked:
        prev = masked
        masked = re.sub(r"\{[^{}]*\}", "", masked)

    def _top(name: str) -> str:
        m = re.search(r"['\"]%s['\"]\s*:\s*['\"]([^'\"]*)['\"]" % re.escape(name), masked)
        return m.group(1) if m else ""

    return {
        "device_id": device_id,
        "session_id": session_id,
        "source_ip": source_ip,
        "key_hash": _top("user_api_key_hash"),
        "key_alias": _top("user_api_key_alias"),
        "team_id": _top("user_api_key_team_id"),
        "key_user_id": _top("user_api_key_user_id"),
    }


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
