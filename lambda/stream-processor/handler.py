import os
import json
import time
import uuid
import logging
import boto3
from datetime import datetime, timezone

from parser import transform_record

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

BUCKET = os.environ.get("AUDIT_BUCKET", "")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "litellm-gw")


def _emit_master_key_metric(count: int) -> None:
    # EMF：由 CloudWatch Logs 异步提取为指标，无需 IAM 变更/额外 API 调用。
    # 告警建在 ops 03-security 栈（{ProjectName}-ops-master-key-usage）。
    # 必须走 print 而非 logger —— Lambda logger 的前缀会破坏 EMF 解析。
    print(json.dumps({
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": f"{PROJECT_NAME}/audit",
                "Dimensions": [[]],
                "Metrics": [{"Name": "MasterKeyRequests", "Unit": "Count"}],
            }],
        },
        "MasterKeyRequests": count,
    }))


def _s3_key(prefix: str, start_time_str: str) -> str:
    try:
        dt = datetime.strptime(start_time_str[:10], "%Y-%m-%d")
    except (ValueError, TypeError):
        dt = datetime.now(timezone.utc)
    ts = int(time.time() * 1000)
    batch_id = uuid.uuid4().hex[:8]
    return f"{prefix}/year={dt.year}/month={dt.month:02d}/day={dt.day:02d}/{ts}-{batch_id}.json"


def handler(event: dict, context) -> dict:
    records = event.get("Records", [])
    processed_lines: list[str] = []
    error_lines: list[str] = []
    master_key_count = 0

    for record in records:
        if record.get("eventName") not in ("INSERT", "MODIFY"):
            continue

        new_image = record.get("dynamodb", {}).get("NewImage", {})

        try:
            transformed = transform_record(new_image)
            if not transformed.get("id") or not transformed.get("start_time"):
                raise ValueError("Record missing required fields")
            # key_alias 为空 = master key（与审计湖/QuickSight key_type 口径一致）
            if not transformed.get("key_alias"):
                master_key_count += 1
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

    if master_key_count:
        _emit_master_key_metric(master_key_count)

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
