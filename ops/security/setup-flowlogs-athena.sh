#!/usr/bin/env bash
# LiteLLM Gateway - Ops: VPC Flow Logs → Athena 取证表 setup
# 在 04-flowlogs 栈落地的 S3 Flow Logs 之上建 Athena 表（分区投影，无需 MSCK），
# 字段顺序与 04-flowlogs.yaml 的 LogFormat 严格一致。
#
# 用法（桶名默认取 04-flowlogs 栈输出）：
#   bash ops/security/setup-flowlogs-athena.sh
# 可选：FLOWLOGS_BUCKET / ATHENA_DB / ATHENA_TABLE / ATHENA_OUTPUT / AWS_REGION / YEAR_RANGE
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
FLOWLOGS_BUCKET="${FLOWLOGS_BUCKET:-$(aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-ops-flowlogs --region $REGION --query "Stacks[0].Outputs[?OutputKey=='FlowLogsBucketName'].OutputValue" --output text 2>/dev/null)}"
: "${FLOWLOGS_BUCKET:?未取到 Flow Logs 桶名（先部署 04-flowlogs 或显式设 FLOWLOGS_BUCKET）}"
ATHENA_DB="${ATHENA_DB:-litellm_gw_security}"
ATHENA_TABLE="${ATHENA_TABLE:-vpc_flow_logs}"
ATHENA_OUTPUT="${ATHENA_OUTPUT:-s3://litellm-gw-audit-${ACCOUNT_ID}/athena-results/}"
YEAR_RANGE="${YEAR_RANGE:-2024,2030}"
[[ "$ATHENA_DB" =~ ^[a-zA-Z0-9_]+$ ]]    || { echo "ERROR: ATHENA_DB 非法" >&2; exit 1; }
[[ "$ATHENA_TABLE" =~ ^[a-zA-Z0-9_]+$ ]] || { echo "ERROR: ATHENA_TABLE 非法" >&2; exit 1; }
REGIONS="us-east-1,us-east-2,us-west-1,us-west-2,eu-west-1,eu-central-1,ap-southeast-1,ap-southeast-2,ap-northeast-1,ap-south-1,ap-east-1,cn-north-1,cn-northwest-1"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

LOCATION="s3://${FLOWLOGS_BUCKET}/AWSLogs/${ACCOUNT_ID}/vpcflowlogs/"
TEMPLATE="s3://${FLOWLOGS_BUCKET}/AWSLogs/${ACCOUNT_ID}/vpcflowlogs/\${region}/\${year}/\${month}/\${day}"

read -r -d '' CREATE_DB <<SQL || true
CREATE DATABASE IF NOT EXISTS \`${ATHENA_DB}\`;
SQL

# 列顺序必须与 04-flowlogs.yaml 的 LogFormat 完全一致
read -r -d '' CREATE_TABLE <<SQL || true
CREATE EXTERNAL TABLE IF NOT EXISTS \`${ATHENA_DB}\`.\`${ATHENA_TABLE}\` (
  version string, account_id string, interface_id string,
  srcaddr string, dstaddr string, srcport int, dstport int,
  protocol bigint, packets bigint, bytes bigint,
  \`start\` bigint, \`end\` bigint, action string, log_status string,
  vpc_id string, subnet_id string, instance_id string, tcp_flags int,
  \`type\` string, pkt_srcaddr string, pkt_dstaddr string,
  az_id string, flow_direction string, traffic_path int
)
PARTITIONED BY (region string, year string, month string, day string)
ROW FORMAT DELIMITED FIELDS TERMINATED BY ' '
LOCATION '${LOCATION}'
TBLPROPERTIES (
  'skip.header.line.count'='1',
  'projection.enabled'='true',
  'projection.region.type'='enum', 'projection.region.values'='${REGIONS}',
  'projection.year.type'='integer', 'projection.year.range'='${YEAR_RANGE}',
  'projection.month.type'='integer', 'projection.month.range'='1,12', 'projection.month.digits'='2',
  'projection.day.type'='integer', 'projection.day.range'='1,31', 'projection.day.digits'='2',
  'storage.location.template'='${TEMPLATE}'
);
SQL

run_athena() {
  local sql="$1" desc="$2" qid st
  log "执行：${desc}"
  qid=$(aws athena start-query-execution --region "$REGION" --query-string "$sql" \
    --result-configuration "OutputLocation=${ATHENA_OUTPUT}" --query QueryExecutionId --output text)
  while true; do
    st=$(aws athena get-query-execution --region "$REGION" --query-execution-id "$qid" \
      --query "QueryExecution.Status.State" --output text)
    case "$st" in
      SUCCEEDED) log "  ✓ ${desc}"; break ;;
      FAILED|CANCELLED) aws athena get-query-execution --region "$REGION" --query-execution-id "$qid" \
        --query "QueryExecution.Status.StateChangeReason" --output text; exit 1 ;;
      *) sleep 2 ;;
    esac
  done
}

run_athena "$CREATE_DB"    "创建数据库 ${ATHENA_DB}"
run_athena "$CREATE_TABLE" "创建表 ${ATHENA_DB}.${ATHENA_TABLE}（分区投影）"

log "========================================="
log " VPC Flow Logs Athena 取证表就绪：${ATHENA_DB}.${ATHENA_TABLE}"
log " 数据位置：${LOCATION}"
log " 注意：Flow Logs 首批记录到 S3 有 ~10 分钟延迟，稍后再查。"
log " 查询在 ops/security/queries/flow-*.sql（{{DB}} 用 sed 替换）"
log "========================================="
