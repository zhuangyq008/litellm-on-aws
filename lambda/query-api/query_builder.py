import re
from datetime import datetime


def _sanitize(value: str) -> str:
    """Remove SQL injection characters and keywords: semicolons, quotes, backslashes, double hyphens, and SQL commands."""
    if not isinstance(value, str):
        return str(value)
    # Remove semicolons, single quotes, backslashes, and SQL comments (--)
    value = value.replace(";", "").replace("'", "").replace("\\", "")
    value = value.replace("--", "")
    # Remove common SQL injection keywords (case-insensitive)
    dangerous_keywords = [
        "DROP", "DELETE", "INSERT", "UPDATE", "CREATE", "ALTER",
        "TRUNCATE", "EXEC", "EXECUTE", "UNION", "SELECT"
    ]
    for keyword in dangerous_keywords:
        value = re.sub(rf'\b{keyword}\b', '', value, flags=re.IGNORECASE)
    return value.strip()


def _generate_partition_filter(start_date: str, end_date: str) -> str:
    start = datetime.strptime(start_date, "%Y-%m-%d")
    end = datetime.strptime(end_date, "%Y-%m-%d")

    partitions = []
    current = start.replace(day=1)
    while current <= end:
        partitions.append((str(current.year), f"{current.month:02d}"))
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


def build_query(params: dict, database: str, table: str) -> str:
    # Dates need special handling to preserve format while preventing injection
    start_date = params.get("start_date", "")
    end_date = params.get("end_date", "")

    # Validate date format (YYYY-MM-DD) - prevents injection
    if not re.match(r'^\d{4}-\d{2}-\d{2}$', start_date):
        raise ValueError(f"Invalid start_date format: {start_date}")
    if not re.match(r'^\d{4}-\d{2}-\d{2}$', end_date):
        raise ValueError(f"Invalid end_date format: {end_date}")

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
        f"FROM \"{database}\".{table} "
        f"WHERE {where_clause} "
        f"ORDER BY start_time DESC "
        f"LIMIT {page_size}"
    )


def build_record_query(record_id: str, database: str, table: str) -> str:
    safe_id = _sanitize(record_id)
    return (
        f"SELECT * "
        f"FROM \"{database}\".{table} "
        f"WHERE id = '{safe_id}' "
        f"LIMIT 1"
    )
