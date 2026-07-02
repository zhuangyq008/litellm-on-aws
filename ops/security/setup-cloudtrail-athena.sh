#!/usr/bin/env bash
# LiteLLM Gateway - Ops: CloudTrail → Athena 取证表 setup
#
# 在已有的 CloudTrail S3 日志之上建一张 Athena 表（分区投影，无需 MSCK），
# 用于事后溯源：谁读了 master key 密钥、IAM/密钥/WAF 变更、root/控制台登录 等。
#
# 用法：
#   CLOUDTRAIL_BUCKET=<你的CloudTrail桶> bash ops/security/setup-cloudtrail-athena.sh
# 可选环境变量：
#   ATHENA_DB       (默认 litellm_gw_security)
#   ATHENA_TABLE    (默认 cloudtrail_logs)
#   ATHENA_OUTPUT   (默认 s3://<CLOUDTRAIL_BUCKET>/athena-results/ ；建议改到你有写权限的桶)
#   AWS_REGION      (默认 us-east-1)
#   YEAR_RANGE      (默认 2024,2030)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
: "${CLOUDTRAIL_BUCKET:?必须设置 CLOUDTRAIL_BUCKET（CloudTrail 日志所在的 S3 桶名，不含 s3://）}"
ATHENA_DB="${ATHENA_DB:-litellm_gw_security}"
ATHENA_TABLE="${ATHENA_TABLE:-cloudtrail_logs}"
ATHENA_OUTPUT="${ATHENA_OUTPUT:-s3://${CLOUDTRAIL_BUCKET}/athena-results/}"
YEAR_RANGE="${YEAR_RANGE:-2024,2030}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------- 1. 探测 AWSLogs 路径结构（org trail: AWSLogs/<orgId>/<acct>/ ; 普通: AWSLogs/<acct>/）----------
log "探测 s3://${CLOUDTRAIL_BUCKET}/ 下的 CloudTrail 路径结构..."
LEVEL1=$(aws s3api list-objects-v2 --bucket "$CLOUDTRAIL_BUCKET" --prefix "AWSLogs/" --delimiter "/" \
  --query "CommonPrefixes[].Prefix" --output text 2>/dev/null | tr '\t' '\n' | head -5)
if echo "$LEVEL1" | grep -q "AWSLogs/o-"; then
  ORG_PREFIX=$(echo "$LEVEL1" | grep "AWSLogs/o-" | head -1)   # AWSLogs/o-xxxx/
  CT_PATH="${ORG_PREFIX}${ACCOUNT_ID}/CloudTrail"
  log "检测到组织级 Trail：${CT_PATH}/"
else
  CT_PATH="AWSLogs/${ACCOUNT_ID}/CloudTrail"
  log "使用账号级路径：${CT_PATH}/"
fi
LOCATION="s3://${CLOUDTRAIL_BUCKET}/${CT_PATH}/"
TEMPLATE="s3://${CLOUDTRAIL_BUCKET}/${CT_PATH}/\${region}/\${year}/\${month}/\${day}"

# 常见 region 枚举（按需增删）
REGIONS="us-east-1,us-east-2,us-west-1,us-west-2,eu-west-1,eu-central-1,ap-southeast-1,ap-southeast-2,ap-northeast-1,ap-south-1,ap-east-1,cn-north-1,cn-northwest-1"

# ---------- 2. 组装 DDL ----------
read -r -d '' CREATE_DB <<SQL || true
CREATE DATABASE IF NOT EXISTS ${ATHENA_DB};
SQL

read -r -d '' CREATE_TABLE <<SQL || true
CREATE EXTERNAL TABLE IF NOT EXISTS ${ATHENA_DB}.${ATHENA_TABLE} (
    eventVersion STRING,
    userIdentity STRUCT<
        type: STRING, principalId: STRING, arn: STRING, accountId: STRING,
        invokedBy: STRING, accessKeyId: STRING, userName: STRING,
        sessionContext: STRUCT<
            attributes: STRUCT<mfaAuthenticated: STRING, creationDate: STRING>,
            sessionIssuer: STRUCT<type: STRING, principalId: STRING, arn: STRING, accountId: STRING, userName: STRING>,
            ec2RoleDelivery: STRING,
            webIdFederationData: MAP<STRING,STRING>
        >
    >,
    eventTime STRING, eventSource STRING, eventName STRING, awsRegion STRING,
    sourceIPAddress STRING, userAgent STRING, errorCode STRING, errorMessage STRING,
    requestParameters STRING, responseElements STRING, additionalEventData STRING,
    requestId STRING, eventId STRING, readOnly STRING,
    resources ARRAY<STRUCT<arn: STRING, accountId: STRING, type: STRING>>,
    eventType STRING, apiVersion STRING, recipientAccountId STRING,
    serviceEventDetails STRING, sharedEventID STRING, vpcEndpointId STRING,
    tlsDetails STRUCT<tlsVersion:STRING, cipherSuite:STRING, clientProvidedHostHeader:STRING>
)
PARTITIONED BY (region STRING, year STRING, month STRING, day STRING)
ROW FORMAT SERDE 'org.apache.hive.hcatalog.data.JsonSerDe'
STORED AS INPUTFORMAT 'com.amazon.emr.cloudtrail.CloudTrailInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat'
LOCATION '${LOCATION}'
TBLPROPERTIES (
  'projection.enabled'='true',
  'projection.region.type'='enum',
  'projection.region.values'='${REGIONS}',
  'projection.year.type'='integer', 'projection.year.range'='${YEAR_RANGE}',
  'projection.month.type'='integer', 'projection.month.range'='1,12', 'projection.month.digits'='2',
  'projection.day.type'='integer', 'projection.day.range'='1,31', 'projection.day.digits'='2',
  'storage.location.template'='${TEMPLATE}'
);
SQL

# ---------- 3. 执行 Athena ----------
run_athena() {
  local sql="$1" desc="$2"
  log "执行：${desc}"
  local qid
  qid=$(aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --result-configuration "OutputLocation=${ATHENA_OUTPUT}" \
    --query "QueryExecutionId" --output text)
  while true; do
    local st
    st=$(aws athena get-query-execution --region "$REGION" --query-execution-id "$qid" \
      --query "QueryExecution.Status.State" --output text)
    case "$st" in
      SUCCEEDED) log "  ✓ ${desc} 完成"; break ;;
      FAILED|CANCELLED)
        log "  ✗ ${desc} 失败："
        aws athena get-query-execution --region "$REGION" --query-execution-id "$qid" \
          --query "QueryExecution.Status.StateChangeReason" --output text
        exit 1 ;;
      *) sleep 2 ;;
    esac
  done
}

run_athena "$CREATE_DB"    "创建数据库 ${ATHENA_DB}"
run_athena "$CREATE_TABLE" "创建表 ${ATHENA_DB}.${ATHENA_TABLE}（分区投影）"

log "========================================="
log " CloudTrail Athena 取证表就绪"
log " 数据库/表 : ${ATHENA_DB}.${ATHENA_TABLE}"
log " 数据位置  : ${LOCATION}"
log " 结果输出  : ${ATHENA_OUTPUT}"
log "========================================="
log "取证查询在 ops/security/queries/ ，用法示例："
log "  aws athena start-query-execution --region ${REGION} \\"
log "    --query-string \"\$(sed 's/{{DB}}/${ATHENA_DB}/g' ops/security/queries/01-master-key-reads.sql)\" \\"
log "    --result-configuration OutputLocation=${ATHENA_OUTPUT}"
