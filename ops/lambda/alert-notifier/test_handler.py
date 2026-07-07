import json
import os

os.environ.setdefault("WEBHOOK_SECRET_ARN", "arn:test")

from handler import _parse_sns  # noqa: E402


def _sns_record(message: str, subject: str = "") -> dict:
    return {"Sns": {"Message": message, "Subject": subject}}


class TestParseSns:
    def test_cloudwatch_alarm_message(self):
        msg = {
            "AlarmName": "litellm-gw-ops-target-5xx",
            "NewStateValue": "ALARM",
            "AlarmDescription": "desc",
            "NewStateReason": "reason",
            "Region": "US East (N. Virginia)",
            "StateChangeTime": "2026-07-07T00:00:00Z",
        }
        title, lines, color = _parse_sns(_sns_record(json.dumps(msg)))
        assert title == "[ALARM] litellm-gw-ops-target-5xx"
        assert color == "red"

    def test_budgets_plain_text_message(self):
        # AWS Budgets 通知是纯文本，不是 JSON
        text = "Dear AWS Customer,\n\nYou requested that we alert you when the ACTUAL Cost ..."
        title, lines, color = _parse_sns(
            _sns_record(text, subject="AWS Budgets: litellm-gw-ops-monthly-cost has exceeded your alert threshold")
        )
        assert "AWS Budgets" in title
        assert any("ACTUAL Cost" in line for line in lines)
        assert color == "orange"

    def test_cost_anomaly_json_message(self):
        msg = {
            "accountId": "284367710968",
            "anomalyId": "abc-123",
            "anomalyStartDate": "2026-07-06T00:00:00Z",
            "anomalyEndDate": "2026-07-07T00:00:00Z",
            "impact": {
                "totalImpact": 231.5,
                "totalActualSpend": 500.0,
                "totalExpectedSpend": 268.5,
            },
            "rootCauses": [{"service": "Amazon Bedrock", "region": "us-east-1", "usageType": "on-demand"}],
            "anomalyDetailsLink": "https://console.aws.amazon.com/cost-management/...",
        }
        title, lines, color = _parse_sns(_sns_record(json.dumps(msg)))
        assert "费用异常" in title
        assert color == "red"
        joined = "\n".join(lines)
        assert "231.5" in joined
        assert "Amazon Bedrock" in joined

    def test_unknown_json_falls_back_to_subject(self):
        title, lines, color = _parse_sns(_sns_record(json.dumps({"foo": "bar"}), subject="Some Subject"))
        assert title == "Some Subject"
        assert color == "orange"
