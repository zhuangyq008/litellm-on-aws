#!/usr/bin/env python3
"""建 QuickSight Analysis + Dashboard（3 页：用量总览 / 安全与异常 / 网络取证）。
基于已建的两个 SPICE 数据集 ds-usage / ds-egress。幂等：先删同名再建。
用法: python3 analytics/quicksight/build-dashboard.py
"""
import boto3

REGION = "us-east-1"
ACCOUNT = "284367710968"
USER_ARN = ("arn:aws:quicksight:us-east-1:284367710968:user/default/"
            "AWSReservedSSO_AdministratorAccess_67f29691e640229a/zhuangyingqin")
USAGE = "arn:aws:quicksight:us-east-1:284367710968:dataset/litellm-gw-ds-usage"
EGRESS = "arn:aws:quicksight:us-east-1:284367710968:dataset/litellm-gw-ds-net"
ANALYSIS_ID = "litellm-gw-analysis"
DASHBOARD_ID = "litellm-gw-dashboard"

qs = boto3.client("quicksight", region_name=REGION)


def cat(ds, col, fid):
    return {"CategoricalDimensionField": {"FieldId": fid, "Column": {"ColumnName": col, "DataSetIdentifier": ds}}}


def date_dim(ds, col, fid):
    return {"DateDimensionField": {"FieldId": fid, "Column": {"ColumnName": col, "DataSetIdentifier": ds},
                                   "DateGranularity": "DAY"}}


def num(ds, col, fid, agg="SUM"):
    return {"NumericalMeasureField": {"FieldId": fid, "Column": {"ColumnName": col, "DataSetIdentifier": ds},
                                      "AggregationFunction": {"SimpleNumericalAggregation": agg}}}


def cnt(ds, col, fid):
    return {"CategoricalMeasureField": {"FieldId": fid, "Column": {"ColumnName": col, "DataSetIdentifier": ds},
                                        "AggregationFunction": "COUNT"}}


def title(text):
    return {"Visibility": "VISIBLE", "FormatText": {"PlainText": text}}


def kpi(vid, text, value_field):
    return {"KPIVisual": {"VisualId": vid, "Title": title(text),
                          "ChartConfiguration": {"FieldWells": {"Values": [value_field]}}}}


def bar(vid, text, category, value):
    return {"BarChartVisual": {"VisualId": vid, "Title": title(text),
            "ChartConfiguration": {"FieldWells": {"BarChartAggregatedFieldWells": {
                "Category": [category], "Values": [value]}}}}}


def line(vid, text, category, value):
    return {"LineChartVisual": {"VisualId": vid, "Title": title(text),
            "ChartConfiguration": {"FieldWells": {"LineChartAggregatedFieldWells": {
                "Category": [category], "Values": [value]}}}}}


def pie(vid, text, category, value):
    return {"PieChartVisual": {"VisualId": vid, "Title": title(text),
            "ChartConfiguration": {"FieldWells": {"PieChartAggregatedFieldWells": {
                "Category": [category], "Values": [value]}}}}}


def grid(visual_ids):
    """两列栅格布局(每格宽 18/36)。"""
    els = []
    for i, vid in enumerate(visual_ids):
        els.append({"ElementId": vid, "ElementType": "VISUAL",
                    "ColumnIndex": (i % 2) * 18, "ColumnSpan": 18,
                    "RowIndex": (i // 2) * 12, "RowSpan": 12})
    return {"GridLayout": {"Elements": els}}


def v_id(v):
    return list(v.values())[0]["VisualId"]


# ---- Sheet 1: 使用总览 ----
s1 = [
    kpi("v_req", "总请求数", cnt("usage", "model", "f_req")),
    kpi("v_tok", "总 Token", num("usage", "total_tokens", "f_tok", "SUM")),
    line("v_trend", "请求量趋势(按天)", date_dim("usage", "request_date", "f_d"), cnt("usage", "model", "f_rc")),
    bar("v_tokmodel", "Token 按模型", cat("usage", "model", "f_m"), num("usage", "total_tokens", "f_tm", "SUM")),
]
# ---- Sheet 2: 安全与异常 ----
s2 = [
    pie("v_mk", "Master key vs Virtual key 用量", cat("usage", "key_type", "f_mk"), cnt("usage", "model", "f_mkc")),
    bar("v_keytok", "Token 按 key_alias(Top 消耗者)", cat("usage", "key_alias", "f_ka"), num("usage", "total_tokens", "f_kt", "SUM")),
    bar("v_finish", "finish_reason 分布", cat("usage", "finish_reason", "f_fr"), cnt("usage", "model", "f_frc")),
    bar("v_teamtok", "Token 按团队", cat("usage", "team_id", "f_tid"), num("usage", "total_tokens", "f_tt", "SUM")),
]
# ---- Sheet 3: 网络取证 ----
s3 = [
    bar("v_egress", "出站字节 Top 目的地", cat("egress", "dest_ip", "f_dip"), num("egress", "bytes", "f_by", "SUM")),
    bar("v_action", "流量按 action(ACCEPT/REJECT)", cat("egress", "action", "f_ac"), num("egress", "flows", "f_fl", "SUM")),
]

definition = {
    "DataSetIdentifierDeclarations": [
        {"Identifier": "usage", "DataSetArn": USAGE},
        {"Identifier": "egress", "DataSetArn": EGRESS},
    ],
    "Sheets": [
        {"SheetId": "s1", "Name": "使用总览", "Visuals": s1, "Layouts": [{"Configuration": grid([v_id(x) for x in s1])}]},
        {"SheetId": "s2", "Name": "安全与异常", "Visuals": s2, "Layouts": [{"Configuration": grid([v_id(x) for x in s2])}]},
        {"SheetId": "s3", "Name": "网络取证", "Visuals": s3, "Layouts": [{"Configuration": grid([v_id(x) for x in s3])}]},
    ],
}

ANALYSIS_PERMS = [{"Principal": USER_ARN, "Actions": [
    "quicksight:RestoreAnalysis", "quicksight:UpdateAnalysisPermissions", "quicksight:DeleteAnalysis",
    "quicksight:DescribeAnalysisPermissions", "quicksight:QueryAnalysis", "quicksight:DescribeAnalysis",
    "quicksight:UpdateAnalysis"]}]
DASHBOARD_PERMS = [{"Principal": USER_ARN, "Actions": [
    "quicksight:DescribeDashboard", "quicksight:ListDashboardVersions", "quicksight:UpdateDashboardPermissions",
    "quicksight:QueryDashboard", "quicksight:UpdateDashboard", "quicksight:DeleteDashboard",
    "quicksight:DescribeDashboardPermissions", "quicksight:UpdateDashboardPublishedVersion"]}]


def _recreate(delete_fn, **kw):
    try:
        delete_fn(**kw)
    except qs.exceptions.ResourceNotFoundException:
        pass
    except Exception as e:  # noqa: BLE001
        print("delete warn:", e)


if __name__ == "__main__":
    _recreate(qs.delete_analysis, AwsAccountId=ACCOUNT, AnalysisId=ANALYSIS_ID, ForceDeleteWithoutRecovery=True)
    _recreate(qs.delete_dashboard, AwsAccountId=ACCOUNT, DashboardId=DASHBOARD_ID)

    print("创建 Analysis ...")
    qs.create_analysis(AwsAccountId=ACCOUNT, AnalysisId=ANALYSIS_ID, Name="LiteLLM GW 看板",
                       Definition=definition, Permissions=ANALYSIS_PERMS)
    print("创建 Dashboard ...")
    qs.create_dashboard(AwsAccountId=ACCOUNT, DashboardId=DASHBOARD_ID, Name="LiteLLM GW 看板",
                        Definition=definition, Permissions=DASHBOARD_PERMS,
                        DashboardPublishOptions={"AdHocFilteringOption": {"AvailabilityStatus": "ENABLED"}})
    print(f"OK: https://{REGION}.quicksight.aws.amazon.com/sn/dashboards/{DASHBOARD_ID}")
