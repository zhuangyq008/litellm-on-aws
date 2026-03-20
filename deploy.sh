#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
TENANT_NAME="${TENANT_NAME:-default}"
REGION="${AWS_REGION:-us-east-1}"
CFN_DIR="$(cd "$(dirname "$0")/cfn" && pwd)"
CONFIG_DIR="$(cd "$(dirname "$0")/config" && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

wait_stack() {
  local stack_name="$1"
  log "Waiting for stack ${stack_name} to complete..."
  aws cloudformation wait stack-create-complete \
    --stack-name "$stack_name" --region "$REGION" 2>/dev/null \
  || aws cloudformation wait stack-update-complete \
    --stack-name "$stack_name" --region "$REGION" 2>/dev/null
  log "Stack ${stack_name} completed."
}

deploy_stack() {
  local stack_name="$1"
  local template_file="$2"
  shift 2
  local params=("$@")

  log "Deploying stack: ${stack_name}"
  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null; then
    aws cloudformation update-stack \
      --stack-name "$stack_name" \
      --template-body "file://${template_file}" \
      --parameters "${params[@]}" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$REGION" 2>/dev/null || {
        log "No updates needed for ${stack_name}, skipping."
        return 0
      }
  else
    aws cloudformation create-stack \
      --stack-name "$stack_name" \
      --template-body "file://${template_file}" \
      --parameters "${params[@]}" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$REGION"
  fi
  wait_stack "$stack_name"
}

# ========== Step 1: VPC ==========
deploy_stack "${PROJECT_NAME}-vpc" "${CFN_DIR}/01-vpc.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

# ========== Step 2: Secrets ==========
deploy_stack "${PROJECT_NAME}-secrets" "${CFN_DIR}/02-secrets.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}"

# ========== Step 3: Data (RDS + Redis + S3) ==========
deploy_stack "${PROJECT_NAME}-data" "${CFN_DIR}/03-data.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}"

# ========== Step 4: Upload LiteLLM Config to S3 ==========
CONFIG_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-data" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ConfigBucketName'].OutputValue" \
  --output text)

log "Uploading litellm-config.yaml to s3://${CONFIG_BUCKET}/"
aws s3 cp "${CONFIG_DIR}/litellm-config.yaml" "s3://${CONFIG_BUCKET}/litellm-config.yaml" --region "$REGION"

# ========== Step 5: ECS + ALB ==========
deploy_stack "${PROJECT_NAME}-ecs" "${CFN_DIR}/04-ecs.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}"

# ========== Step 5.1: Verify ALB Listener (self-heal) ==========
# CloudFormation has a known issue where ALB Listener can be marked CREATE_COMPLETE
# but actually be missing after stack rebuild/rollback. This check ensures it exists.
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "${PROJECT_NAME}-alb" --region "$REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null) || true

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  LISTENER_COUNT=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" --region "$REGION" \
    --query "length(Listeners)" --output text 2>/dev/null)
  if [ "$LISTENER_COUNT" = "0" ]; then
    log "WARNING: ALB Listener missing (known CFN drift issue). Recreating..."
    TG_ARN=$(aws elbv2 describe-target-groups \
      --names "${PROJECT_NAME}-tg" --region "$REGION" \
      --query "TargetGroups[0].TargetGroupArn" --output text)
    aws elbv2 create-listener \
      --load-balancer-arn "$ALB_ARN" \
      --protocol HTTP --port 80 \
      --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
      --region "$REGION" > /dev/null
    log "ALB Listener recreated successfully."
  else
    log "ALB Listener OK."
  fi
fi

# ========== Step 6: CloudFront ==========
deploy_stack "${PROJECT_NAME}-cloudfront" "${CFN_DIR}/05-cloudfront.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

# ========== Output ==========
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-ecs" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text)

CF_DOMAIN=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-cloudfront" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomainName'].OutputValue" \
  --output text)

CF_DIST_ID=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-cloudfront" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
  --output text)

echo ""
log "========================================="
log " Deployment Complete!"
log " LiteLLM Gateway (ALB):        http://${ALB_DNS}"
log " LiteLLM Gateway (CloudFront): https://${CF_DOMAIN}"
log " CloudFront Distribution ID:   ${CF_DIST_ID}"
log "========================================="
echo ""
log "NEXT STEPS:"
log "  1. Update API keys in Secrets Manager:"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/openai --secret-string '{\"api_key\":\"sk-xxx\"}'"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/anthropic --secret-string '{\"api_key\":\"sk-ant-xxx\"}'"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/gemini --secret-string '{\"api_key\":\"AIxxx\"}'"
log "  2. Force new ECS deployment to pick up secrets:"
log "     aws ecs update-service --cluster ${PROJECT_NAME}-cluster --service ${PROJECT_NAME}-service --force-new-deployment --region ${REGION}"
log "  3. Verify health (via CloudFront): curl https://${CF_DOMAIN}/health/liveliness"
log "  4. (Optional) Add custom domain: configure CNAME + ACM certificate in CloudFront"
