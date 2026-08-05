#!/usr/bin/env bash
# LiteLLM Gateway - Ops 独立部署脚本
# 与主 deploy.sh 完全解耦：仅只读引用主栈导出，可独立部署/卸载。
# 用法：
#   cp ops/params.example.env ops/params.env   # 填入 webhook / 白名单 / 阈值
#   bash ops/deploy-ops.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
REGION="${AWS_REGION:-us-east-1}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------- 载入参数 ----------
PARAMS_FILE="${SCRIPT_DIR}/params.env"
if [ ! -f "$PARAMS_FILE" ]; then
  echo "ERROR: 未找到 ${PARAMS_FILE}，请先 cp params.example.env params.env 并填写。" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$PARAMS_FILE"

: "${IM_TYPE:?IM_TYPE 未设置}"
: "${WEBHOOK_URL:?WEBHOOK_URL 未设置}"
WEBHOOK_SIGN_SECRET="${WEBHOOK_SIGN_SECRET:-}"
ENABLE_ADMIN_LOCKDOWN="${ENABLE_ADMIN_LOCKDOWN:-false}"
ALLOWED_ADMIN_CIDRS="${ALLOWED_ADMIN_CIDRS:-0.0.0.0/32}"
if [ "$ENABLE_ADMIN_LOCKDOWN" = "true" ] && [ "$ALLOWED_ADMIN_CIDRS" = "0.0.0.0/32" ]; then
  echo "ERROR: ENABLE_ADMIN_LOCKDOWN=true 时必须设置真实的 ALLOWED_ADMIN_CIDRS（运维出口 IP）。" >&2
  exit 1
fi
RATE_LIMIT_PER_KEY="${RATE_LIMIT_PER_KEY:-3000}"
RATE_LIMIT_PER_IP="${RATE_LIMIT_PER_IP:-20000}"
ENABLE_GEO_BLOCK="${ENABLE_GEO_BLOCK:-false}"
# 告警阈值（客户可按实际基线覆盖；默认值按 2000+ 员工规模校准）
HTTP_4XX_THRESHOLD="${HTTP_4XX_THRESHOLD:-1000}"
HTTP_5XX_THRESHOLD="${HTTP_5XX_THRESHOLD:-25}"
LATENCY_P95_THRESHOLD="${LATENCY_P95_THRESHOLD:-45}"
REQUEST_ANOMALY_STDEV="${REQUEST_ANOMALY_STDEV:-3}"
NAT_EGRESS_THRESHOLD_BYTES="${NAT_EGRESS_THRESHOLD_BYTES:-524288000}"
NAT_EGRESS_BURST_THRESHOLD_BYTES="${NAT_EGRESS_BURST_THRESHOLD_BYTES:-104857600}"
MASTER_KEY_USAGE_THRESHOLD="${MASTER_KEY_USAGE_THRESHOLD:-0}"
MONTHLY_BUDGET_USD="${MONTHLY_BUDGET_USD:-5000}"
COST_ANOMALY_THRESHOLD_USD="${COST_ANOMALY_THRESHOLD_USD:-100}"
EXISTING_ANOMALY_MONITOR_ARN="${EXISTING_ANOMALY_MONITOR_ARN:-}"
ALLOWED_COUNTRIES="${ALLOWED_COUNTRIES:-CN}"
TARGET_GROUP_FULL_NAME="${TARGET_GROUP_FULL_NAME:-}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: 需要 jq 来安全构造密钥 JSON。" >&2; exit 1; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ARTIFACT_BUCKET="${PROJECT_NAME}-ops-artifacts-${ACCOUNT_ID}"

MON_STACK="${PROJECT_NAME}-ops-monitoring"
WAF_STACK="${PROJECT_NAME}-ops-waf"
SEC_STACK="${PROJECT_NAME}-ops-security"
FL_STACK="${PROJECT_NAME}-ops-flowlogs"
COST_STACK="${PROJECT_NAME}-ops-cost"
GUARDDUTY_SEVERITY="${GUARDDUTY_SEVERITY:-4}"
MASTER_KEY_PATTERN="${MASTER_KEY_PATTERN:-*master-key*}"

# ---------- 前置检查：主栈导出 ----------
if ! aws cloudformation list-exports --region "$REGION" \
      --query "Exports[?Name=='${PROJECT_NAME}-ALBArn'].Value" --output text | grep -q .; then
  echo "ERROR: 未找到主栈导出 ${PROJECT_NAME}-ALBArn，请先部署主栈 (${PROJECT_NAME}-ecs)。" >&2
  exit 1
fi

# ---------- 工件桶 ----------
if ! aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" 2>/dev/null; then
  log "创建工件桶 ${ARTIFACT_BUCKET}"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-encryption --bucket "$ARTIFACT_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
fi

# ========== Step 1: monitoring 栈（含 Lambda 打包）==========
log "打包 monitoring 模板 (上传 alert-notifier Lambda 到 ${ARTIFACT_BUCKET})"
aws cloudformation package \
  --template-file "${SCRIPT_DIR}/cfn/01-monitoring.yaml" \
  --s3-bucket "$ARTIFACT_BUCKET" \
  --s3-prefix ops-lambda \
  --output-template-file /tmp/ops-monitoring.packaged.yaml \
  --region "$REGION"

log "部署 ${MON_STACK}"
aws cloudformation deploy \
  --template-file /tmp/ops-monitoring.packaged.yaml \
  --stack-name "$MON_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "ImType=${IM_TYPE}" \
    "TargetGroupFullName=${TARGET_GROUP_FULL_NAME}" \
    "Http4xxThreshold=${HTTP_4XX_THRESHOLD}" \
    "Http5xxThreshold=${HTTP_5XX_THRESHOLD}" \
    "TargetResponseTimeThreshold=${LATENCY_P95_THRESHOLD}" \
    "RequestCountAnomalyStdev=${REQUEST_ANOMALY_STDEV}"

SNS_ARN="$(aws cloudformation describe-stacks --stack-name "$MON_STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='AlertTopicArn'].OutputValue" --output text)"
log "SNS 告警主题: ${SNS_ARN}"

# 写入 IM webhook 密钥（用 put-secret-value：CloudTrail 对密钥体脱敏，jq 保证 JSON 转义正确）
SECRET_ARN="$(aws cloudformation describe-stacks --stack-name "$MON_STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='WebhookSecretArn'].OutputValue" --output text)"
log "写入 IM webhook 密钥到 ${SECRET_ARN}"
SECRET_JSON="$(jq -nc --arg u "$WEBHOOK_URL" --arg s "$WEBHOOK_SIGN_SECRET" \
  '{webhook_url:$u, sign_secret:$s}')"
aws secretsmanager put-secret-value --secret-id "$SECRET_ARN" \
  --secret-string "$SECRET_JSON" --region "$REGION" >/dev/null

# ========== Step 2: WAF 栈 ==========
log "部署 ${WAF_STACK}"
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/cfn/02-waf.yaml" \
  --stack-name "$WAF_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "EnableAdminLockdown=${ENABLE_ADMIN_LOCKDOWN}" \
    "AllowedAdminCidrs=${ALLOWED_ADMIN_CIDRS}" \
    "RateLimitPerKey=${RATE_LIMIT_PER_KEY}" \
    "RateLimitPerIp=${RATE_LIMIT_PER_IP}" \
    "EnableGeoBlock=${ENABLE_GEO_BLOCK}" \
    "AllowedCountries=${ALLOWED_COUNTRIES}" \
    "AlertTopicArn=${SNS_ARN}"

# ========== Step 3: 安全事件告警栈（GuardDuty / 密钥读取 / root 登录）==========
log "部署 ${SEC_STACK}"
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/cfn/03-security.yaml" \
  --stack-name "$SEC_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "GuardDutySeverityThreshold=${GUARDDUTY_SEVERITY}" \
    "MasterKeyNamePattern=${MASTER_KEY_PATTERN}" \
    "MasterKeyUsageThreshold=${MASTER_KEY_USAGE_THRESHOLD}"

# ========== Step 4: VPC Flow Logs → S3 取证 + NAT 出站流量告警 ==========
VPCID="$(aws cloudformation list-exports --region "$REGION" \
  --query "Exports[?Name=='${PROJECT_NAME}-VpcId'].Value" --output text)"
mapfile -t NATS < <(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=vpc-id,Values=${VPCID}" "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayId" --output text | tr '\t' '\n')
log "部署 ${FL_STACK}（NAT: ${NATS[*]:-none}）"
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/cfn/04-flowlogs.yaml" \
  --stack-name "$FL_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "NatGatewayId1=${NATS[0]:-}" \
    "NatGatewayId2=${NATS[1]:-}" \
    "NatEgressThresholdBytes=${NAT_EGRESS_THRESHOLD_BYTES}" \
    "NatEgressBurstThresholdBytes=${NAT_EGRESS_BURST_THRESHOLD_BYTES}"

# ========== Step 5: 成本告警（Budgets + Cost Anomaly Detection）==========
log "部署 ${COST_STACK}"
aws cloudformation deploy \
  --template-file "${SCRIPT_DIR}/cfn/05-cost.yaml" \
  --stack-name "$COST_STACK" \
  --region "$REGION" \
  --parameter-overrides \
    "ProjectName=${PROJECT_NAME}" \
    "MonthlyBudgetAmount=${MONTHLY_BUDGET_USD}" \
    "CostAnomalyThresholdUsd=${COST_ANOMALY_THRESHOLD_USD}" \
    "ExistingAnomalyMonitorArn=${EXISTING_ANOMALY_MONITOR_ARN}"

# ========== 输出 ==========
DASH_URL="https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${PROJECT_NAME}-ops"
echo ""
log "========================================="
log " Ops 模块部署完成"
log " 告警主题:   ${SNS_ARN}"
log " Dashboard:  ${DASH_URL}"
log " WAF WebACL: ${PROJECT_NAME}-ops-acl (已关联 ALB)"
log " 安全告警:   GuardDuty(sev>=${GUARDDUTY_SEVERITY}) / master key 读取 / root 登录 → 飞书"
log " Flow Logs:  VPC→S3 取证 + NAT 出站流量告警(建表: ops/security/setup-flowlogs-athena.sh)"
log " 成本告警:   月度预算 \$${MONTHLY_BUDGET_USD}(实际80%/预测100%) + 费用异常(≥\$${COST_ANOMALY_THRESHOLD_USD}) → 飞书"
log "========================================="
log "卸载：aws cloudformation delete-stack --stack-name ${COST_STACK} --region ${REGION}"
log "      aws cloudformation delete-stack --stack-name ${FL_STACK} --region ${REGION}"
log "      aws cloudformation delete-stack --stack-name ${SEC_STACK} --region ${REGION}"
log "      aws cloudformation delete-stack --stack-name ${WAF_STACK} --region ${REGION}"
log "      aws cloudformation delete-stack --stack-name ${MON_STACK} --region ${REGION}"
