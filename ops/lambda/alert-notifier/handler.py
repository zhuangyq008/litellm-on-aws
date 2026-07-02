"""
LiteLLM Gateway - Ops 告警通知适配器

入口：SNS 事件（CloudWatch 告警：ALB/ECS/WAF 原生指标）。
统一格式化成飞书 / 钉钉 / 企业微信群机器人消息卡片后推送。
webhook URL 与加签密钥从 Secrets Manager 读取（仅授予本函数读取单个 secret）。
只依赖标准库，无需 pip 依赖。
"""
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request
import urllib.error
import urllib.parse

import boto3

IM_TYPE = os.environ.get("IM_TYPE", "feishu").lower()      # feishu | dingtalk | wecom
SECRET_ARN = os.environ["WEBHOOK_SECRET_ARN"]
REGION = os.environ.get("AWS_REGION", "us-east-1")

_secrets_client = boto3.client("secretsmanager", region_name=REGION)
_cache = {}  # 冷启动缓存 secret


def _get_webhook_config():
    """从 Secrets Manager 读取 {webhook_url, sign_secret}，缓存于容器生命周期内。"""
    if "cfg" not in _cache:
        raw = _secrets_client.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        _cache["cfg"] = json.loads(raw)
    return _cache["cfg"]


def _parse_sns(record):
    """解析 CloudWatch Alarm -> SNS 的消息体，归一化为 (title, lines[], color)。"""
    return _alarm_to_msg(json.loads(record["Sns"]["Message"]))


def _alarm_to_msg(msg):
    """把告警形状的 dict 归一化为 (title, lines[], color)。
    既用于 CloudWatch Alarm→SNS，也用于 EventBridge 经 Input Transformer 塑形后的直调事件
    （GuardDuty / 密钥读取 / root 登录等安全事件）。"""
    state = msg.get("NewStateValue", "UNKNOWN")
    color = {"ALARM": "red", "OK": "green", "INSUFFICIENT_DATA": "grey"}.get(state, "orange")
    title = f"[{state}] {msg.get('AlarmName', 'CloudWatch Alarm')}"
    lines = [
        f"**描述**：{msg.get('AlarmDescription') or '-'}",
        f"**原因**：{msg.get('NewStateReason', '-')}",
        f"**区域**：{msg.get('Region', '-')}",
        f"**时间**：{msg.get('StateChangeTime', '-')}",
    ]
    return title, lines, color


# ---------------------------------------------------------------------------
# 消息构造：三种 IM 平台（注意飞书与钉钉的加签算法不同）
# ---------------------------------------------------------------------------
def _feishu_payload(title, lines, color, sign_secret):
    body = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {"tag": "plain_text", "content": title},
                "template": color,
            },
            "elements": [
                {"tag": "div", "text": {"tag": "lark_md", "content": "\n".join(lines)}}
            ],
        },
    }
    if sign_secret:
        # 飞书规范：key = "{timestamp}\n{secret}"，待签消息为空。与钉钉相反，勿混用。
        ts = str(int(time.time()))
        string_to_sign = f"{ts}\n{sign_secret}"
        sign = base64.b64encode(
            hmac.new(string_to_sign.encode(), b"", hashlib.sha256).digest()
        ).decode()
        body["timestamp"] = ts
        body["sign"] = sign
    return body, None


def _dingtalk_payload(title, lines, color, sign_secret):
    body = {
        "msgtype": "markdown",
        "markdown": {"title": title, "text": f"### {title}\n\n" + "\n\n".join(lines)},
    }
    query = None
    if sign_secret:
        # 钉钉规范：key = secret，待签消息 = "{timestamp}\n{secret}"，签名放 URL query。
        ts = str(round(time.time() * 1000))
        string_to_sign = f"{ts}\n{sign_secret}"
        sign = base64.b64encode(
            hmac.new(sign_secret.encode(), string_to_sign.encode(), hashlib.sha256).digest()
        ).decode()
        query = f"&timestamp={ts}&sign={urllib.parse.quote_plus(sign)}"
    return body, query


def _wecom_payload(title, lines, color, sign_secret):
    body = {
        "msgtype": "markdown",
        "markdown": {"content": f"### {title}\n" + "\n".join(lines)},
    }
    return body, None


_BUILDERS = {"feishu": _feishu_payload, "dingtalk": _dingtalk_payload, "wecom": _wecom_payload}


def _send(title, lines, color):
    cfg = _get_webhook_config()
    url = cfg["webhook_url"]
    sign_secret = cfg.get("sign_secret", "")

    builder = _BUILDERS.get(IM_TYPE, _feishu_payload)
    body, query = builder(title, lines, color, sign_secret)
    if query:
        url = url + query

    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"IM push ok: status={resp.status} title={title}")
    except urllib.error.HTTPError as e:
        print(f"IM push HTTPError {e.code}: {e.read().decode(errors='ignore')}")
        raise
    except Exception as e:  # noqa: BLE001
        print(f"IM push failed: {e}")
        raise


def handler(event, context):
    # 入口 A：CloudWatch Alarm → SNS
    if isinstance(event, dict) and "Records" in event:
        for record in event["Records"]:
            if record.get("EventSource") == "aws:sns" or "Sns" in record:
                title, lines, color = _parse_sns(record)
                _send(title, lines, color)
        return {"ok": True}

    # 入口 B：EventBridge 直调（安全事件），已由 Input Transformer 塑形成告警形状
    if isinstance(event, dict) and "AlarmName" in event:
        title, lines, color = _alarm_to_msg(event)
        _send(title, lines, color)
        return {"ok": True}

    print(f"Unrecognized event shape: {json.dumps(event)[:500]}")
    return {"ok": False, "reason": "unrecognized event"}
