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

# ========== Step 7: Package and upload Lambda functions ==========
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

log "Step 7: Packaging Lambda functions..."

cd "${SCRIPT_DIR}/lambda/stream-processor"
zip -r /tmp/stream-processor.zip handler.py parser.py
aws s3 cp /tmp/stream-processor.zip "s3://${CONFIG_BUCKET}/lambda/stream-processor.zip" --region "$REGION"
cd "$SCRIPT_DIR"

cd "${SCRIPT_DIR}/lambda/query-api"
zip -r /tmp/query-api.zip handler.py query_builder.py
aws s3 cp /tmp/query-api.zip "s3://${CONFIG_BUCKET}/lambda/query-api.zip" --region "$REGION"
cd "$SCRIPT_DIR"

log "Lambda packages uploaded to S3"

# ========== Step 8: Deploy Audit Pipeline stack ==========
deploy_stack "${PROJECT_NAME}-audit-pipeline" "${CFN_DIR}/06-audit-pipeline.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

# ========== Step 9: Deploy Audit UI stack ==========
deploy_stack "${PROJECT_NAME}-audit-ui" "${CFN_DIR}/07-audit-ui.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

# ========== Step 10: Build and deploy SPA ==========
log "Step 10: Building and deploying Audit UI SPA..."

AUDIT_API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' --output text)
COGNITO_POOL_ID=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoUserPoolId`].OutputValue' --output text)
COGNITO_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoClientId`].OutputValue' --output text)
COGNITO_DOMAIN=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoDomain`].OutputValue' --output text)
SPA_BUCKET=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaBucketName`].OutputValue' --output text)
SPA_CF_ID=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDistributionId`].OutputValue' --output text)

cd "${SCRIPT_DIR}/audit-ui"
VITE_API_ENDPOINT="$AUDIT_API_ENDPOINT" \
VITE_COGNITO_USER_POOL_ID="$COGNITO_POOL_ID" \
VITE_COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN" \
npm run build

aws s3 sync dist/ "s3://${SPA_BUCKET}/" --delete --region "$REGION"
aws cloudfront create-invalidation --distribution-id "$SPA_CF_ID" --paths "/*" --region "$REGION"
cd "$SCRIPT_DIR"

SPA_DOMAIN=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-audit-ui" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDomain`].OutputValue' --output text)

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
log " Audit UI:                     https://${SPA_DOMAIN}"
log " Audit API:                    ${AUDIT_API_ENDPOINT}"
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
log "  4. Create Cognito admin user:"
log "     aws cognito-idp admin-create-user --user-pool-id ${COGNITO_POOL_ID} --username admin@example.com --temporary-password 'TempPass123!' --user-attributes Name=email,Value=admin@example.com Name=email_verified,Value=true --region ${REGION}"
log "  5. Update Cognito callback URL:"
log "     aws cognito-idp update-user-pool-client --user-pool-id ${COGNITO_POOL_ID} --client-id ${COGNITO_CLIENT_ID} --callback-urls https://${SPA_DOMAIN} --logout-urls https://${SPA_DOMAIN} --allowed-o-auth-flows code --allowed-o-auth-scopes openid email profile --allowed-o-auth-flows-user-pool-client --supported-identity-providers COGNITO --region ${REGION}"
