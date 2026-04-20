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
