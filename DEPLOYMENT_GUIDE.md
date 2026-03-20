# LiteLLM Gateway 部署指南

## 1. 方案概述

本方案在 AWS 上部署 LiteLLM Proxy 作为统一的大模型 API 网关，提供 OpenAI 兼容的 API 接口，统一代理 OpenAI、Anthropic、Google Gemini、AWS Bedrock 等多家模型服务商。

### 1.1 架构图

```
                       ┌─────────────────────────────────────────────────────┐
                       │                     VPC (10.0.0.0/16)               │
                       │                                                     │
  ┌──────────┐  HTTPS  │  ┌─────────────────────────────────────────────┐    │
  │          │────────>┌──────────────┐                                      │
  │  Client  │         │  CloudFront  │   │         Public Subnets           │
  │          │         │  (HTTPS/H2)  │   │  ┌─────────────┐  ┌─────────┐  │
  └──────────┘         └──────┬───────┘   │  │  ALB         │  │  NAT GW │  │
                       │      │ HTTP:80   │  └──────┬──────┘  └─────────┘  │
                       │      └──────────>│─────────┘                       │
                       │  └─────────────────────────────────────────────┘    │
                       │            │ :4000                                  │
                       │  ┌─────────┼──────────────────────────────────┐    │
                       │  │         ▼     Private Subnets (dual-AZ)    │    │
                       │  │  ┌─────────────────┐                       │    │
                       │  │  │  ECS Fargate     │                       │    │
                       │  │  │  (2 replicas)    │                       │    │
                       │  │  └──┬──────┬──────┬┘                       │    │
                       │  │     │      │      │                         │    │
                       │  │     ▼      ▼      ▼                         │    │
                       │  │  ┌─────┐┌─────┐┌──────────┐                │    │
                       │  │  │ RDS ││Redis││ Bedrock  │                │    │
                       │  │  │ PG  ││ TLS ││ (IAM)   │                │    │
                       │  │  └─────┘└─────┘└──────────┘                │    │
                       │  └────────────────────────────────────────────┘    │
                       └─────────────────────────────────────────────────────┘
```

### 1.2 组件清单

| 组件 | AWS 服务 | 规格 |
|---|---|---|
| 网络 | VPC + 双 AZ 子网 | 10.0.0.0/16, 2 公网 + 2 私有子网 |
| CDN/HTTPS | CloudFront | HTTPS 终结, HTTP/2+3, 全球边缘加速 |
| 负载均衡 | Application Load Balancer | Internal (经 CloudFront 访问) |
| 计算 | ECS Fargate | 1 vCPU / 4GB 内存 / 2 副本 |
| 数据库 | RDS PostgreSQL 16 | db.m7g.large, Multi-AZ, 加密存储 |
| 缓存 | ElastiCache Redis Serverless | 自动扩缩容, TLS 加密 |
| 密钥管理 | Secrets Manager | 按租户/提供商命名空间管理 |
| 配置存储 | S3 | 版本化, 加密 |
| 日志 | CloudWatch Logs | 保留 30 天 |

---

## 2. 前置条件

### 2.1 AWS 环境要求

- AWS 账号, 具有 Administrator 或同等权限的 IAM 用户/角色
- AWS CLI v2 已安装并配置 (`aws configure`)
- 目标区域: `us-east-1` (可按需修改)

### 2.2 验证 AWS 访问

```bash
aws sts get-caller-identity
aws configure get region
```

确认输出显示正确的账号和区域。

### 2.3 Bedrock 模型访问

需要在 AWS Bedrock 控制台为目标区域开通以下模型的访问权限:

1. 登录 AWS 控制台 -> Amazon Bedrock -> Model access
2. 申请开通以下模型:
   - `Anthropic Claude Opus 4.6`
   - `Anthropic Claude Haiku 4.5`
3. 等待状态变为 "Access granted"

### 2.4 准备 API Keys（按需）

如需使用非 Bedrock 提供商，请提前准备:

| 提供商 | 获取方式 |
|---|---|
| OpenAI | https://platform.openai.com/api-keys |
| Anthropic | https://console.anthropic.com/settings/keys |
| Google Gemini | https://aistudio.google.com/apikey |

---

## 3. 交付物说明

```
litellm-gw/
├── cfn/                           # CloudFormation 模板
│   ├── 01-vpc.yaml                #   网络层: VPC, 子网, NAT, 路由
│   ├── 02-secrets.yaml            #   密钥层: Secrets Manager
│   ├── 03-data.yaml               #   数据层: RDS, Redis, S3
│   ├── 04-ecs.yaml                #   应用层: ECS, ALB, IAM, CloudWatch
│   └── 05-cloudfront.yaml         #   CDN层: CloudFront HTTPS 加速
├── config/
│   └── litellm-config.yaml        # LiteLLM 路由配置 (模型列表)
└── deploy.sh                      # 一键部署脚本
```

---

## 4. 部署步骤

### 4.1 获取部署包

将交付的 `litellm-gw/` 目录上传至部署机器（需有 AWS CLI 权限的 EC2 或本地工作站）。

```bash
cd litellm-gw
chmod +x deploy.sh
```

### 4.2 （可选）修改部署参数

如需自定义项目名称、租户名或区域，编辑环境变量：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PROJECT_NAME` | `litellm-gw` | 所有资源的命名前缀 |
| `TENANT_NAME` | `default` | Secrets Manager 中的租户命名空间 |
| `AWS_REGION` | `us-east-1` | 部署目标区域 |

### 4.3 （可选）修改模型列表

编辑 `config/litellm-config.yaml`，按需增删模型。格式示例：

```yaml
model_list:
  - model_name: my-model-alias        # 调用时使用的名称
    litellm_params:
      model: bedrock/us.anthropic.claude-opus-4-6-v1   # 实际模型 ID
      aws_region_name: us-east-1
```

> **注意**: Bedrock 模型 ID 必须使用 cross-region inference profile 格式（以 `us.` 开头），不能使用原始模型 ID。

### 4.4 执行部署

```bash
./deploy.sh
```

或指定自定义参数：

```bash
PROJECT_NAME=litellm-gw TENANT_NAME=myteam AWS_REGION=us-east-1 ./deploy.sh
```

脚本将按顺序创建 5 个 CloudFormation 堆栈，全程约 **20-25 分钟**（RDS Multi-AZ 和 CloudFront 创建耗时较长）。

各阶段预估时间:

| 阶段 | 预估时间 |
|---|---|
| Step 1: VPC 网络 | 2 分钟 |
| Step 2: Secrets 密钥 | 1 分钟 |
| Step 3: RDS + Redis + S3 | 10-15 分钟 |
| Step 4: 上传配置到 S3 | < 1 分钟 |
| Step 5: ECS + ALB | 3-5 分钟 |
| Step 6: CloudFront CDN | 3-5 分钟 |

脚本执行成功后会输出 CloudFront HTTPS 访问地址和 ALB 内网地址。

### 4.5 配置 API Keys

部署完成后，Secrets Manager 中的第三方 API Key 为占位符，需手动替换为真实值：

```bash
# OpenAI
aws secretsmanager update-secret \
  --secret-id litellm/default/openai \
  --secret-string '{"api_key":"sk-proj-xxxxxxxxx"}' \
  --region us-east-1

# Anthropic
aws secretsmanager update-secret \
  --secret-id litellm/default/anthropic \
  --secret-string '{"api_key":"sk-ant-xxxxxxxxx"}' \
  --region us-east-1

# Google Gemini
aws secretsmanager update-secret \
  --secret-id litellm/default/gemini \
  --secret-string '{"api_key":"AIzaSyxxxxxxxxx"}' \
  --region us-east-1
```

> 如果只使用 Bedrock 模型，可跳过此步骤。Bedrock 通过 ECS Task Role 的 IAM 权限访问，无需 API Key。

### 4.6 重启服务使密钥生效

```bash
aws ecs update-service \
  --cluster litellm-gw-cluster \
  --service litellm-gw-service \
  --force-new-deployment \
  --region us-east-1
```

等待约 2 分钟，新任务启动后即可使用更新后的密钥。

---

## 5. 部署验证

### 5.1 健康检查

```bash
# 通过 CloudFront (推荐, HTTPS)
curl https://<CLOUDFRONT_DOMAIN>/health/liveliness

# 或直接通过 ALB (仅内部调试)
curl http://<ALB_DNS>/health/liveliness
```

预期返回:

```json
"I'm alive!"
```

### 5.2 获取 Master Key

Master Key 是管理员凭证，部署时自动生成，存储在 Secrets Manager 中：

```bash
aws secretsmanager get-secret-value \
  --secret-id litellm/default/master-key \
  --region us-east-1 \
  --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])"
```

> 请妥善保存此 Key，后续所有 API 调用和管理操作均需要此凭证。

### 5.3 查看已注册模型

```bash
curl -s https://<CLOUDFRONT_DOMAIN>/model/info \
  -H "Authorization: Bearer <MASTER_KEY>" \
  | python3 -c "
import sys,json
models = json.load(sys.stdin)['data']
for m in models:
    print(f\"  {m['model_name']:30s} -> {m['litellm_params']['model']}\")
"
```

### 5.4 发送测试请求

```bash
curl https://<CLOUDFRONT_DOMAIN>/chat/completions \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-opus",
    "messages": [
      {"role": "user", "content": "Hello, which model are you?"}
    ],
    "max_tokens": 200
  }'
```

预期返回标准 OpenAI 格式的 JSON 响应。

---

## 6. 已配置模型列表

| 调用名称 | 提供商 | 底层模型 | 认证方式 |
|---|---|---|---|
| `bedrock-claude-opus` | AWS Bedrock | Claude Opus 4.6 | IAM Role（自动） |
| `bedrock-claude-haiku` | AWS Bedrock | Claude Haiku 4.5 | IAM Role（自动） |
| `gpt-4o` | OpenAI | GPT-4o | API Key |
| `gpt-4o-mini` | OpenAI | GPT-4o Mini | API Key |
| `gpt-4.1` | OpenAI | GPT-4.1 | API Key |
| `claude-sonnet-4-20250514` | Anthropic API | Claude Sonnet 4 | API Key |
| `claude-haiku-4-5-20251001` | Anthropic API | Claude Haiku 4.5 | API Key |
| `gemini-2.0-flash` | Google | Gemini 2.0 Flash | API Key |
| `gemini-2.5-pro` | Google | Gemini 2.5 Pro | API Key |

---

## 7. 日常运维

### 7.1 更新模型配置

```bash
# 1. 编辑配置文件
vim config/litellm-config.yaml

# 2. 上传到 S3
aws s3 cp config/litellm-config.yaml \
  s3://litellm-gw-config-<ACCOUNT_ID>/litellm-config.yaml \
  --region us-east-1

# 3. 滚动重启 ECS 服务
aws ecs update-service \
  --cluster litellm-gw-cluster \
  --service litellm-gw-service \
  --force-new-deployment \
  --region us-east-1
```

### 7.2 查看日志

```bash
# 实时追踪最近日志
aws logs tail /ecs/litellm-gw --follow --region us-east-1

# 搜索错误日志
aws logs filter-log-events \
  --log-group-name /ecs/litellm-gw \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region us-east-1
```

也可在 AWS 控制台中通过 **CloudWatch -> Log groups -> /ecs/litellm-gw** 查看。

### 7.3 扩缩容

```bash
# 调整副本数（示例: 扩展到 4 个）
aws ecs update-service \
  --cluster litellm-gw-cluster \
  --service litellm-gw-service \
  --desired-count 4 \
  --region us-east-1
```

### 7.4 查看 CloudFormation 堆栈状态

```bash
aws cloudformation describe-stacks \
  --region us-east-1 \
  --query "Stacks[?starts_with(StackName,'litellm-gw')].{Name:StackName,Status:StackStatus}" \
  --output table
```

---

## 8. 清理/卸载

如需完全卸载，**按逆序**删除堆栈:

```bash
aws cloudformation delete-stack --stack-name litellm-gw-cloudfront --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name litellm-gw-cloudfront --region us-east-1

aws cloudformation delete-stack --stack-name litellm-gw-ecs --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name litellm-gw-ecs --region us-east-1

aws cloudformation delete-stack --stack-name litellm-gw-data --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name litellm-gw-data --region us-east-1

aws cloudformation delete-stack --stack-name litellm-gw-secrets --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name litellm-gw-secrets --region us-east-1

aws cloudformation delete-stack --stack-name litellm-gw-vpc --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name litellm-gw-vpc --region us-east-1
```

> **注意**: RDS 设置了 `DeletionProtection: true`，删除前需在控制台或 CLI 中先关闭删除保护。
> S3 存储桶需手动清空后才能删除。

---

## 9. 常见问题

### Q1: 部署脚本报错 "Cannot find version xx.x for postgres"

**原因**: 目标区域不支持该 PostgreSQL 版本。

**解决**: 查询可用版本并修改 `cfn/03-data.yaml` 中的 `EngineVersion`:

```bash
aws rds describe-db-engine-versions \
  --engine postgres \
  --query "DBEngineVersions[?starts_with(EngineVersion,'16')].EngineVersion" \
  --output text --region us-east-1
```

### Q2: ECS 任务反复重启, 日志显示 "Child process [xxx] died"

**原因**: 内存不足 (OOM)。

**解决**: 在 `cfn/04-ecs.yaml` 中将 `TaskMemory` 从 `2048` 提升至 `4096`，同时确保 `--num_workers` 不超过 2。

### Q3: Bedrock 调用返回 "on-demand throughput isn't supported"

**原因**: 新版 Bedrock 模型不支持直接 on-demand 调用，需使用 inference profile。

**解决**: 在 `config/litellm-config.yaml` 中，模型 ID 使用 cross-region inference profile 格式:

```yaml
# 错误 ❌
model: bedrock/anthropic.claude-opus-4-6-v1:0

# 正确 ✅
model: bedrock/us.anthropic.claude-opus-4-6-v1
```

### Q4: 部署后 curl 返回 "Connection refused"

**原因**: ALB Listener 可能在堆栈重建过程中丢失。

**解决**:

```bash
# 检查 Listener
aws elbv2 describe-listeners \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names litellm-gw-alb --region us-east-1 \
    --query "LoadBalancers[0].LoadBalancerArn" --output text) \
  --region us-east-1

# 如果 Listeners 为空, 手动创建
ALB_ARN=$(aws elbv2 describe-load-balancers --names litellm-gw-alb --region us-east-1 --query "LoadBalancers[0].LoadBalancerArn" --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names litellm-gw-tg --region us-east-1 --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --region us-east-1
```

### Q5: CloudFormation 堆栈删除失败，提示 ElastiCache 状态异常

**原因**: ElastiCache Serverless 缓存尚未就绪（正在创建或删除中）。

**解决**: 等待缓存状态变为 `available` 后重试:

```bash
# 查看状态
aws elasticache describe-serverless-caches \
  --serverless-cache-name litellm-gw-redis \
  --region us-east-1 \
  --query "ServerlessCaches[0].Status"

# 状态为 available 后重试删除
aws cloudformation delete-stack --stack-name litellm-gw-data --region us-east-1
```

### Q6: 如何限制 ALB 只接受 CloudFront 流量?

**方案 A**: 使用 AWS 托管前缀列表限制 ALB 安全组:

```bash
# 获取 CloudFront 托管前缀列表 ID
PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
  --region us-east-1 \
  --query "PrefixLists[0].PrefixListId" --output text)

# 更新 ALB 安全组: 移除 0.0.0.0/0, 添加 CloudFront 前缀列表
```

**方案 B**: 在 ALB 前添加 AWS WAF，校验 `X-CloudFront-Verify` 自定义头部。CloudFront 发出的请求会自动带上此头部（值为 CloudFormation Stack ID 的一部分）。

### Q7: 如何为 CloudFront 绑定自定义域名?

1. 在 **ACM (us-east-1 区域)** 申请证书:
   ```bash
   aws acm request-certificate \
     --domain-name api.example.com \
     --validation-method DNS \
     --region us-east-1
   ```
2. 完成 DNS 验证后，更新 `cfn/05-cloudfront.yaml`，添加 `Aliases` 和 `ViewerCertificate`:
   ```yaml
   Aliases:
     - api.example.com
   ViewerCertificate:
     AcmCertificateArn: arn:aws:acm:us-east-1:xxx:certificate/xxx
     SslSupportMethod: sni-only
     MinimumProtocolVersion: TLSv1.2_2021
   ```
3. 在 DNS 中添加 CNAME 记录: `api.example.com -> <CloudFront域名>.cloudfront.net`

### Q8: CloudFront 删除堆栈很慢?

**原因**: CloudFront 分发需要先 Disable 再 Delete，全球边缘节点同步需要时间。

**解决**: 耐心等待，通常需要 5-15 分钟。删除期间状态会变为 `InProgress`。

---

## 10. 安全建议

| 项目 | 当前状态 | 建议 |
|---|---|---|
| HTTPS | CloudFront 提供 HTTPS 终结 | 已满足生产要求; 可添加自定义域名 + ACM 证书 |
| ALB 访问 | 0.0.0.0/0 | 建议限制为仅 CloudFront 来源 (见下方 Q6) |
| CloudFront 验证 | X-CloudFront-Verify 自定义头 | 可配合 WAF 规则校验此头部以限制直连 ALB |
| Master Key | 自动生成 | 定期轮换, 限制知悉范围 |
| RDS | Multi-AZ + 加密 | 已满足生产要求 |
| Redis | TLS 加密 | 已满足生产要求 |
| NAT Gateway | 单节点 | 高可用场景可部署双 NAT |
