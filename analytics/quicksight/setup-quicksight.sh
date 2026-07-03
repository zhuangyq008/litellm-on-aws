#!/usr/bin/env bash
# LiteLLM Gateway - QuickSight 数据源 + SPICE 数据集 setup
# 前提：策展视图已建(views.sql)、QuickSight 已订阅(Enterprise)、
#      QuickSight 服务角色对 Athena/Glue/审计桶/flowlogs桶/结果桶有读权限。
# 用法： bash analytics/quicksight/setup-quicksight.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
WORKGROUP="${ATHENA_WORKGROUP:-litellm-gw-audit}"
DS_ID="litellm-gw-athena"
DS_ARN="arn:aws:quicksight:${REGION}:${ACCOUNT_ID}:datasource/${DS_ID}"
# 授权主体：默认取账号里第一个 QuickSight 用户（可用 QS_USER_ARN 覆盖）
QS_USER_ARN="${QS_USER_ARN:-$(aws quicksight list-users --aws-account-id "$ACCOUNT_ID" --namespace default --region "$REGION" --query 'UserList[0].Arn' --output text)}"
: "${QS_USER_ARN:?未找到 QuickSight 用户}"
QS_ROLE="${QS_ROLE:-aws-quicksight-service-role-v0}"
AUDIT_BUCKET="${AUDIT_BUCKET:-litellm-gw-audit-${ACCOUNT_ID}}"
FLOWLOGS_BUCKET="${FLOWLOGS_BUCKET:-litellm-gw-ops-flowlogs-${ACCOUNT_ID}}"
log() { echo "[$(date '+%H:%M:%S')] $*"; }
log "QS 用户: ${QS_USER_ARN}"

# ---------- 0. 给 QuickSight 服务角色最小权限 S3(QS+Athena 前提) ----------
# QS 跑 Athena 查询时，服务角色需读源数据桶 + 写 Athena 结果。缺失会导致 SPICE 摄取
# PERMISSION_DENIED(s3:ListBucket)。put-role-policy 幂等。
# 桶名校验(防变量注入进 IAM 策略 JSON)
[[ "$AUDIT_BUCKET" =~ ^[a-z0-9.-]+$ ]]    || { echo "ERROR: AUDIT_BUCKET 名非法" >&2; exit 1; }
[[ "$FLOWLOGS_BUCKET" =~ ^[a-z0-9.-]+$ ]] || { echo "ERROR: FLOWLOGS_BUCKET 名非法" >&2; exit 1; }
log "授予 QS 服务角色 ${QS_ROLE} 对源桶的最小权限 S3(仅 Athena 实际读写的前缀)"
aws iam put-role-policy --role-name "$QS_ROLE" --policy-name litellm-gw-quicksight-s3 \
  --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[
 {"Sid":"QSList","Effect":"Allow","Action":"s3:ListBucket","Resource":["arn:aws:s3:::${AUDIT_BUCKET}","arn:aws:s3:::${FLOWLOGS_BUCKET}"]},
 {"Sid":"QSReadData","Effect":"Allow","Action":"s3:GetObject","Resource":["arn:aws:s3:::${AUDIT_BUCKET}/logs/*","arn:aws:s3:::${FLOWLOGS_BUCKET}/AWSLogs/*"]},
 {"Sid":"QSResults","Effect":"Allow","Action":["s3:PutObject","s3:GetObject","s3:AbortMultipartUpload"],"Resource":"arn:aws:s3:::${AUDIT_BUCKET}/athena-results/*"}
]}
JSON
)" 2>&1 && log "  ✓ S3 权限已附加" || log "  ⚠ 附加失败(需 IAM 权限；或改用 QS 控制台 Security & permissions 勾选桶)"

DS_PERMS="$(cat <<JSON
[{"Principal":"${QS_USER_ARN}","Actions":["quicksight:DescribeDataSource","quicksight:DescribeDataSourcePermissions","quicksight:PassDataSource","quicksight:UpdateDataSource","quicksight:UpdateDataSourcePermissions","quicksight:DeleteDataSource"]}]
JSON
)"
SET_PERMS="$(cat <<JSON
[{"Principal":"${QS_USER_ARN}","Actions":["quicksight:DescribeDataSet","quicksight:DescribeDataSetPermissions","quicksight:PassDataSet","quicksight:DescribeIngestion","quicksight:ListIngestions","quicksight:UpdateDataSet","quicksight:UpdateDataSetPermissions","quicksight:DeleteDataSet","quicksight:CreateIngestion","quicksight:CancelIngestion"]}]
JSON
)"

# ---------- 1. Athena 数据源 ----------
if aws quicksight describe-data-source --aws-account-id "$ACCOUNT_ID" --data-source-id "$DS_ID" --region "$REGION" >/dev/null 2>&1; then
  log "数据源 ${DS_ID} 已存在，跳过"
else
  log "创建 Athena 数据源 ${DS_ID}（workgroup=${WORKGROUP}）"
  aws quicksight create-data-source --region "$REGION" \
    --aws-account-id "$ACCOUNT_ID" --data-source-id "$DS_ID" \
    --name "LiteLLM GW Athena" --type ATHENA \
    --data-source-parameters "{\"AthenaParameters\":{\"WorkGroup\":\"${WORKGROUP}\"}}" \
    --permissions "$DS_PERMS" >/dev/null
  sleep 5
fi

# ---------- 2. 数据集 ----------
create_dataset() {
  local id="$1" name="$2" schema="$3" view="$4" cols="$5"
  local ptm
  ptm="$(cat <<JSON
{"t":{"RelationalTable":{"DataSourceArn":"${DS_ARN}","Catalog":"AwsDataCatalog","Schema":"${schema}","Name":"${view}","InputColumns":${cols}}}}
JSON
)"
  log "创建/更新数据集 ${id}（SPICE）"
  aws quicksight delete-data-set --aws-account-id "$ACCOUNT_ID" --data-set-id "$id" --region "$REGION" >/dev/null 2>&1 || true
  aws quicksight create-data-set --region "$REGION" \
    --aws-account-id "$ACCOUNT_ID" --data-set-id "$id" --name "$name" \
    --import-mode SPICE \
    --physical-table-map "$ptm" \
    --permissions "$SET_PERMS" >/dev/null
  # 触发 SPICE 摄取
  aws quicksight create-ingestion --region "$REGION" \
    --aws-account-id "$ACCOUNT_ID" --data-set-id "$id" \
    --ingestion-id "init-$(date +%s)" >/dev/null 2>&1 \
    && log "  ✓ ${id} 已触发 SPICE 摄取" \
    || log "  ⚠ ${id} 摄取触发失败(多半是 QS 服务角色缺 S3/Athena 权限，见 README)"
}

USAGE_COLS='[{"Name":"request_ts","Type":"DATETIME"},{"Name":"request_date","Type":"DATETIME"},{"Name":"model","Type":"STRING"},{"Name":"call_type","Type":"STRING"},{"Name":"finish_reason","Type":"STRING"},{"Name":"prompt_tokens","Type":"INTEGER"},{"Name":"completion_tokens","Type":"INTEGER"},{"Name":"total_tokens","Type":"INTEGER"},{"Name":"cached_tokens","Type":"INTEGER"},{"Name":"reasoning_tokens","Type":"INTEGER"},{"Name":"cache_hit_ratio","Type":"DECIMAL"},{"Name":"has_tool_calls","Type":"BOOLEAN"},{"Name":"message_count","Type":"INTEGER"},{"Name":"key_alias","Type":"STRING"},{"Name":"key_hash","Type":"STRING"},{"Name":"team_id","Type":"STRING"},{"Name":"key_user_id","Type":"STRING"},{"Name":"key_type","Type":"STRING"},{"Name":"session_id","Type":"STRING"},{"Name":"device_id","Type":"STRING"},{"Name":"source_ip","Type":"STRING"},{"Name":"year","Type":"STRING"},{"Name":"month","Type":"STRING"},{"Name":"day","Type":"STRING"}]'
EGRESS_COLS='[{"Name":"year","Type":"STRING"},{"Name":"month","Type":"STRING"},{"Name":"day","Type":"STRING"},{"Name":"region","Type":"STRING"},{"Name":"action","Type":"STRING"},{"Name":"flow_direction","Type":"STRING"},{"Name":"dest_ip","Type":"STRING"},{"Name":"dest_port","Type":"INTEGER"},{"Name":"interface_id","Type":"STRING"},{"Name":"is_external","Type":"BOOLEAN"},{"Name":"flows","Type":"INTEGER"},{"Name":"bytes","Type":"DECIMAL"},{"Name":"packets","Type":"INTEGER"}]'

create_dataset "litellm-gw-ds-usage"  "LiteLLM GW 用量与安全"  "litellm-gw_audit"      "vw_qs_usage"  "$USAGE_COLS"
create_dataset "litellm-gw-ds-net" "LiteLLM GW 网络出站"    "litellm_gw_security"   "vw_qs_egress" "$EGRESS_COLS"

log "========================================="
log " QuickSight 数据源与数据集就绪。到 QuickSight 控制台用这两个 SPICE 数据集拖拽建 Analysis："
log "   ds-usage  → Sheet1 用量总览 / Sheet2 token / Sheet3 安全与异常"
log "   ds-egress → Sheet4 网络取证"
log " 若摄取失败：Manage QuickSight → Security & permissions → 勾选 Athena + 相关 S3 桶"
log "========================================="
