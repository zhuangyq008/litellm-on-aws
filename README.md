# LiteLLM Gateway - AWS Deployment

## Architecture

```
Internet -> CloudFront (HTTPS) -> ALB (HTTP:80, dual-AZ) -> ECS Fargate (private subnets, 2 replicas)
                                          |-> RDS PostgreSQL 16.13 (m7g.large, Multi-AZ)
                                          |-> ElastiCache Redis Serverless (TLS)
                                          |-> AWS Bedrock (IAM Role)
```

## Access

| Resource | Endpoint |
|---|---|
| LiteLLM Gateway (HTTPS) | `https://<YOUR-CLOUDFRONT-DOMAIN>` |
| LiteLLM Gateway (ALB) | `http://<YOUR-ALB-DNS>` |
| Health Check | `GET /health/liveliness` |
| Model Info | `GET /model/info` (requires auth) |
| Chat Completions | `POST /chat/completions` (OpenAI-compatible) |

## Authentication

Master key stored in Secrets Manager: `litellm/default/master-key`

Retrieve it:
```bash
aws secretsmanager get-secret-value \
  --secret-id litellm/default/master-key \
  --region us-east-1 \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])"
```

Use in API calls:
```bash
curl http://<YOUR-ALB-DNS>/chat/completions \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-opus",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 200
  }'
```

## Available Models

| Model Name | Provider | Model ID |
|---|---|---|
| `bedrock-claude-opus` | AWS Bedrock | `us.anthropic.claude-opus-4-6-v1` |
| `bedrock-claude-haiku` | AWS Bedrock | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `gpt-4o` | OpenAI | `openai/gpt-4o` |
| `gpt-4o-mini` | OpenAI | `openai/gpt-4o-mini` |
| `gpt-4.1` | OpenAI | `openai/gpt-4.1` |
| `claude-sonnet-4-20250514` | Anthropic API | `anthropic/claude-sonnet-4-20250514` |
| `claude-haiku-4-5-20251001` | Anthropic API | `anthropic/claude-haiku-4-5-20251001` |
| `gemini-2.0-flash` | Google | `gemini/gemini-2.0-flash` |
| `gemini-2.5-pro` | Google | `gemini/gemini-2.5-pro-preview-05-06` |

Bedrock models use IAM Task Role (no API key needed). Other providers require API keys in Secrets Manager.

## Update API Keys

```bash
aws secretsmanager update-secret --secret-id litellm/default/openai \
  --secret-string '{"api_key":"sk-xxx"}' --region us-east-1

aws secretsmanager update-secret --secret-id litellm/default/anthropic \
  --secret-string '{"api_key":"sk-ant-xxx"}' --region us-east-1

aws secretsmanager update-secret --secret-id litellm/default/gemini \
  --secret-string '{"api_key":"AIxxx"}' --region us-east-1

# Restart ECS to pick up new secrets
aws ecs update-service --cluster litellm-gw-cluster --service litellm-gw-service \
  --force-new-deployment --region us-east-1
```

## Update LiteLLM Config

1. Edit `config/litellm-config.yaml`
2. Upload: `aws s3 cp config/litellm-config.yaml s3://litellm-gw-config-<YOUR-ACCOUNT-ID>/litellm-config.yaml`
3. Redeploy: `aws ecs update-service --cluster litellm-gw-cluster --service litellm-gw-service --force-new-deployment --region us-east-1`

## CloudFormation Stacks

| Stack | Resources |
|---|---|
| `litellm-gw-vpc` | VPC, 2 public + 2 private subnets, IGW, NAT GW |
| `litellm-gw-secrets` | Secrets Manager (tenant/provider namespace) |
| `litellm-gw-data` | RDS PostgreSQL, ElastiCache Redis Serverless, S3 config bucket |
| `litellm-gw-ecs` | ECS Fargate cluster, ALB, Task Definition, CloudWatch logs |
| `litellm-gw-cloudfront` | CloudFront distribution (HTTPS, HTTP/2+3) |

## Troubleshooting / Known Issues

### 1. PostgreSQL version not available in region
- **Symptom**: RDS creation fails with "Cannot find version 16.4 for postgres"
- **Fix**: Check available versions with `aws rds describe-db-engine-versions --engine postgres` and use the latest (e.g., `16.13`)

### 2. ECS worker processes crash (OOM)
- **Symptom**: Logs show `Child process [xxx] died` repeatedly with no error message
- **Fix**: Increase task memory from 2048MB to 4096MB, reduce `--num_workers` from 4 to 2

### 3. Bedrock models require inference profiles
- **Symptom**: `BedrockException - Invocation of model ID xxx with on-demand throughput isn't supported`
- **Fix**: Use cross-region inference profile IDs (prefix `us.`), e.g., `us.anthropic.claude-opus-4-6-v1` instead of `anthropic.claude-opus-4-6-v1:0`

### 4. ALB Listener lost after stack delete/recreate
- **Symptom**: ALB exists but no listener, `Connection refused` on port 80
- **Fix**: Manually create listener or redeploy the ECS stack. Check with `aws elbv2 describe-listeners`

### 5. ElastiCache Serverless delete fails during stack rollback
- **Symptom**: Stack delete fails with "Serverless cache is not in an available state"
- **Fix**: Wait for cache to reach `available` state, then retry `aws cloudformation delete-stack`
