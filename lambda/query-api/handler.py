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


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False, default=str),
    }


def _parse_route(event: dict) -> tuple:
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


def _submit_query(event: dict) -> dict:
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


def _get_results(execution_id: str) -> dict:
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


def _get_record(record_id: str) -> dict:
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


def handler(event: dict, context) -> dict:
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
