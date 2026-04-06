# LiteLLM 模型配置指南

> 基于 LiteLLM v1.82.x 官方文档及实际部署经验总结。
> 项目地址: https://github.com/BerriAI/litellm
> 官方文档: https://docs.litellm.ai/

---

## 目录

1. [配置方式对比：config.yaml vs UI](#1-配置方式对比configyaml-vs-ui)
2. [config.yaml 核心结构](#2-configyaml-核心结构)
3. [各 Provider 配置详解](#3-各-provider-配置详解)
4. [Bedrock 模型 ID 格式（重点）](#4-bedrock-模型-id-格式重点)
5. [litellm_params 参数参考](#5-litellm_params-参数参考)
6. [路由、负载均衡与故障转移](#6-路由负载均衡与故障转移)
7. [缓存配置（Redis）](#7-缓存配置redis)
8. [日志与回调](#8-日志与回调)
9. [Virtual Key 与团队管理](#9-virtual-key-与团队管理)
10. [健康检查与连接测试](#10-健康检查与连接测试)
11. [踩坑记录与最佳实践](#11-踩坑记录与最佳实践)
12. [完整配置示例](#12-完整配置示例)

---

## 1. 配置方式对比：config.yaml vs UI

LiteLLM 支持两种模型管理方式：

| 维度 | config.yaml（推荐） | UI Model Management |
|------|---------------------|---------------------|
| **版本控制** | Git 管理，可审计 | 仅存在于数据库，无版本历史 |
| **生效方式** | 上传 S3 + 重新部署 ECS | 即时生效，无需重启 |
| **前置条件** | 无 | 需要 `store_model_in_db: true` + 数据库 |
| **适用场景** | 生产环境、基础设施即代码 | 快速测试、临时添加模型 |
| **风险** | 低（IaC 流程保障） | **高（已知 bug，见踩坑记录）** |

### 推荐策略

- **Bedrock 模型** → 必须用 config.yaml（UI 添加会注入多余字段导致调用失败）
- **API Key 类模型**（OpenAI、Anthropic、Gemini）→ config.yaml 或 UI 均可
- **临时测试模型** → 可用 UI，测试完删除

---

## 2. config.yaml 核心结构

```yaml
# ---- 模型列表 ----
model_list:
  - model_name: <用户调用时的名称>
    litellm_params:
      model: <provider>/<model-id>
      api_key: os.environ/<ENV_VAR>     # API Key 认证
      aws_region_name: us-east-1         # Bedrock 认证
    model_info:                          # 可选：元信息
      id: <自定义 ID>
      weight: 0.7                        # 路由权重

# ---- 全局设置 ----
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true

# ---- LiteLLM 行为设置 ----
litellm_settings:
  num_retries: 3
  request_timeout: 600
  drop_params: true
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    ssl: true

# ---- 路由设置（可选） ----
router_settings:
  routing_strategy: simple-shuffle
  fallbacks:
    - gpt-4: ["claude-opus", "bedrock-claude"]
```

### 关键字段说明

| 字段 | 说明 |
|------|------|
| `model_name` | 用户调用时使用的名称（可自定义，多个相同 `model_name` 实现负载均衡） |
| `litellm_params.model` | 格式为 `<provider>/<model-id>`，provider 决定调用哪个 API |
| `os.environ/<VAR>` | 引用环境变量，**禁止硬编码密钥** |
| `drop_params` | 自动丢弃 Provider 不支持的参数（**强烈建议开启**） |
| `store_model_in_db` | 启用后可通过 UI/API 管理模型（存储在 PostgreSQL） |

---

## 3. 各 Provider 配置详解

### 3.1 OpenAI

```yaml
- model_name: gpt-4o
  litellm_params:
    model: openai/gpt-4o
    api_key: os.environ/OPENAI_API_KEY

- model_name: gpt-4o-mini
  litellm_params:
    model: openai/gpt-4o-mini
    api_key: os.environ/OPENAI_API_KEY

- model_name: gpt-4.1
  litellm_params:
    model: openai/gpt-4.1
    api_key: os.environ/OPENAI_API_KEY
```

**认证：** API Key（`OPENAI_API_KEY`）

**可选参数：**
- `api_base`: 自定义 endpoint（用于代理或兼容 API）
- `organization`: OpenAI Organization ID

---

### 3.2 Anthropic（直连 API）

```yaml
- model_name: claude-sonnet-4-20250514
  litellm_params:
    model: anthropic/claude-sonnet-4-20250514
    api_key: os.environ/ANTHROPIC_API_KEY

- model_name: claude-haiku-4-5-20251001
  litellm_params:
    model: anthropic/claude-haiku-4-5-20251001
    api_key: os.environ/ANTHROPIC_API_KEY
```

**认证：** API Key（`ANTHROPIC_API_KEY`）

**Provider 前缀：** `anthropic/`

---

### 3.3 AWS Bedrock

```yaml
# 跨区域推理（推荐）
- model_name: bedrock-claude-opus
  litellm_params:
    model: bedrock/us.anthropic.claude-opus-4-6-v1
    aws_region_name: us-east-1

# 跨区域推理
- model_name: bedrock-claude-sonnet
  litellm_params:
    model: bedrock/us.anthropic.claude-sonnet-4-6
    aws_region_name: us-east-1

# 标准区域调用
- model_name: bedrock-claude-haiku
  litellm_params:
    model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
    aws_region_name: us-east-1
```

**认证方式（按优先级）：**

| 方式 | 适用场景 | 配置 |
|------|---------|------|
| **IAM Task Role** | ECS Fargate / EKS（推荐） | 仅需 `aws_region_name`，无需 Key |
| **Instance Profile** | EC2 | 同上 |
| **Access Key** | 本地开发 | `aws_access_key_id` + `aws_secret_access_key` |
| **Profile** | 本地多账号 | `aws_profile_name: my-profile` |

**IAM 权限要求：**
```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream"
  ],
  "Resource": "*"
}
```

> 详细 Bedrock 模型 ID 格式见 [第 4 节](#4-bedrock-模型-id-格式重点)。

---

### 3.4 Google Gemini（AI Studio）

```yaml
- model_name: gemini-2.0-flash
  litellm_params:
    model: gemini/gemini-2.0-flash
    api_key: os.environ/GEMINI_API_KEY

- model_name: gemini-2.5-pro
  litellm_params:
    model: gemini/gemini-2.5-pro-preview-05-06
    api_key: os.environ/GEMINI_API_KEY
```

**认证：** API Key（`GEMINI_API_KEY`）

**Provider 前缀：** `gemini/`

---

### 3.5 Google Vertex AI

```yaml
- model_name: gemini-vertex
  litellm_params:
    model: vertex_ai/gemini-pro
    vertex_project: your-gcp-project-id
    vertex_location: us-central1
    # 方式1: 服务账号 JSON
    vertex_credentials: os.environ/GOOGLE_APPLICATION_CREDENTIALS
    # 方式2: 在 GCE/GKE 上使用 ADC，无需配置凭证
```

---

### 3.6 Azure OpenAI

```yaml
- model_name: azure-gpt-4
  litellm_params:
    model: azure/gpt-4-deployment-name    # 使用部署名称
    api_key: os.environ/AZURE_API_KEY
    api_base: https://your-resource.openai.azure.com
    api_version: "2024-02-15-preview"
```

**认证方式：**
- API Key: `api_key`
- Azure AD Token: `azure_ad_token: os.environ/AZURE_AD_TOKEN`

---

### 3.7 其他 Provider

| Provider | 前缀 | 认证 | 示例 |
|----------|------|------|------|
| **Mistral** | `mistral/` | API Key | `model: mistral/mistral-large-latest` |
| **Cohere** | `cohere/` | API Key | `model: cohere/command-r-plus` |
| **Groq** | `groq/` | API Key | `model: groq/llama3-70b-8192` |
| **Together AI** | `together_ai/` | API Key | `model: together_ai/meta-llama/Llama-3-70b-chat-hf` |
| **OpenRouter** | `openrouter/` | API Key | `model: openrouter/anthropic/claude-3-opus` |
| **Ollama** | `ollama/` | 无（本地） | `model: ollama/llama2` + `api_base: http://localhost:11434` |
| **Replicate** | `replicate/` | API Key | `model: replicate/meta/llama-2-70b-chat` |
| **Hugging Face** | `huggingface/` | API Key | `model: huggingface/tiiuae/falcon-7b-instruct` |

---

## 4. Bedrock 模型 ID 格式（重点）

### 三种格式

| 前缀 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `anthropic.*` | 标准区域 | 在单个 AWS Region 内调用 | `bedrock/anthropic.claude-sonnet-4-6` |
| `us.anthropic.*` | 美国跨区域推理 | 请求自动路由到美国可用区域 | `bedrock/us.anthropic.claude-sonnet-4-6` |
| `eu.anthropic.*` | 欧洲跨区域推理 | 请求自动路由到欧洲可用区域 | `bedrock/eu.anthropic.claude-sonnet-4-6` |
| `global.anthropic.*` | 全球跨区域推理 | 请求自动路由到全球可用区域 | `bedrock/global.anthropic.claude-sonnet-4-6` |

### 查询可用模型

```bash
# 查看基础模型（标准区域）
aws bedrock list-foundation-models --region us-east-1 \
  --query 'modelSummaries[?contains(modelId, `claude`)].{id:modelId, name:modelName}' \
  --output table

# 查看推理配置文件（跨区域）
aws bedrock list-inference-profiles --region us-east-1 \
  --query 'inferenceProfileSummaries[?contains(inferenceProfileId, `claude`)].{id:inferenceProfileId, name:inferenceProfileName, type:type}' \
  --output table
```

### 当前可用的 Claude 模型（us-east-1）

| LiteLLM model 值 | 模型名称 | 类型 |
|------------------|---------|------|
| `bedrock/anthropic.claude-sonnet-4-6` | Claude Sonnet 4.6 | 标准区域 |
| `bedrock/anthropic.claude-sonnet-4-20250514-v1:0` | Claude Sonnet 4 | 标准区域 |
| `bedrock/anthropic.claude-sonnet-4-5-20250929-v1:0` | Claude Sonnet 4.5 | 标准区域 |
| `bedrock/us.anthropic.claude-opus-4-6-v1` | Claude Opus 4.6 | 美国跨区域 |
| `bedrock/us.anthropic.claude-sonnet-4-6` | Claude Sonnet 4.6 | 美国跨区域 |
| `bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0` | Claude Haiku 4.5 | 美国跨区域 |
| `bedrock/global.anthropic.claude-sonnet-4-6` | Claude Sonnet 4.6 | 全球跨区域 |

### 选择建议

- **生产环境推荐 `us.` 跨区域推理**：自动故障转移，高可用
- **成本敏感场景用标准区域** `anthropic.*`：无跨区域开销
- **全球部署用 `global.*`**：自动路由到最近区域

---

## 5. litellm_params 参数参考

### 核心参数

```yaml
litellm_params:
  # --- 必填 ---
  model: "provider/model-id"

  # --- 认证（按 Provider 选择） ---
  api_key: os.environ/API_KEY            # OpenAI, Anthropic, Gemini 等
  api_base: "https://custom-endpoint/v1" # 自定义 endpoint
  api_version: "2024-02-15-preview"      # Azure 版本号
  aws_region_name: "us-east-1"           # Bedrock
  aws_access_key_id: os.environ/KEY      # Bedrock（非 IAM Role）
  aws_secret_access_key: os.environ/SEC  # Bedrock（非 IAM Role）
  aws_profile_name: "my-profile"         # Bedrock（本地 Profile）
  vertex_project: "gcp-project-id"       # Vertex AI
  vertex_location: "us-central1"         # Vertex AI

  # --- 模型参数（传递给 Provider） ---
  max_tokens: 4096
  temperature: 0.7
  top_p: 1.0
  stop: ["END"]

  # --- 超时与重试 ---
  timeout: 600           # 非流式请求超时（秒）
  stream_timeout: 300    # 流式请求超时（秒）
  max_retries: 3         # 模型级重试次数
```

### 环境变量引用语法

```yaml
# 推荐写法
api_key: os.environ/OPENAI_API_KEY

# 也支持
api_key: ${OPENAI_API_KEY}

# 禁止：硬编码密钥
api_key: "sk-proj-xxx"   # NEVER DO THIS
```

---

## 6. 路由、负载均衡与故障转移

### 负载均衡（相同 model_name）

多个配置使用相同 `model_name`，LiteLLM 自动负载均衡：

```yaml
model_list:
  # 同一 model_name 的多个后端
  - model_name: gpt-4
    litellm_params:
      model: openai/gpt-4
      api_key: os.environ/OPENAI_API_KEY_1
    model_info:
      weight: 0.6    # 60% 流量

  - model_name: gpt-4
    litellm_params:
      model: azure/gpt-4
      api_key: os.environ/AZURE_API_KEY
      api_base: https://your-resource.openai.azure.com
    model_info:
      weight: 0.4    # 40% 流量
```

### 路由策略

```yaml
router_settings:
  routing_strategy: simple-shuffle       # 随机（默认）
  # routing_strategy: least-busy         # 最少并发
  # routing_strategy: latency-based-routing  # 最低延迟
  num_retries: 2
  timeout: 30
  cooldown_time: 60   # 失败后冷却时间（秒）
```

### 故障转移（Fallback）

```yaml
model_list:
  - model_name: primary-llm
    litellm_params:
      model: openai/gpt-4
      api_key: os.environ/OPENAI_API_KEY

  - model_name: fallback-llm
    litellm_params:
      model: anthropic/claude-sonnet-4-20250514
      api_key: os.environ/ANTHROPIC_API_KEY

router_settings:
  fallbacks:
    - primary-llm: ["fallback-llm"]
  allowed_fails_per_minute: 5
```

---

## 7. 缓存配置（Redis）

```yaml
litellm_settings:
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD   # 可选
    ssl: true                              # TLS 加密（ElastiCache 必须）
    ttl: 3600                              # 缓存过期时间（秒）
    namespace: "litellm"                   # Key 前缀（可选）
```

**缓存命中条件：** model + messages + temperature + max_tokens 等参数完全一致。

**生产建议：**
- 使用 Redis（而非 local 内存缓存）以支持多副本共享
- ElastiCache Serverless 配合 `ssl: true`
- 合理设置 TTL，避免返回过期内容

---

## 8. 日志与回调

### DynamoDB 审计日志

```yaml
litellm_settings:
  success_callback: ["dynamodb"]
  failure_callback: ["dynamodb"]
  dynamodb_table_name: litellm-gw-audit-log
```

**记录字段：** request_id, model, messages, response, usage (tokens), startTime, endTime, user, metadata

**IAM 权限要求：**
```json
{
  "Effect": "Allow",
  "Action": ["dynamodb:PutItem", "dynamodb:BatchWriteItem"],
  "Resource": "arn:aws:dynamodb:*:*:table/litellm-gw-audit-log"
}
```

### 多回调

```yaml
litellm_settings:
  success_callback: ["dynamodb", "langfuse", "s3"]
  failure_callback: ["dynamodb", "sentry"]

  # Langfuse
  langfuse_public_key: os.environ/LANGFUSE_PUBLIC_KEY
  langfuse_secret_key: os.environ/LANGFUSE_SECRET_KEY
  langfuse_host: https://cloud.langfuse.com

  # S3
  s3_callback_params:
    bucket_name: litellm-logs
    region_name: us-east-1
```

### 日志级别

```yaml
litellm_settings:
  set_verbose: false          # true = DEBUG 日志（调试时开启）
  json_logs: true             # JSON 格式（便于 CloudWatch 查询）
  log_raw_request_response: false  # 不记录原始请求/响应（保护 PII）
```

---

## 9. Virtual Key 与团队管理

### 创建 Virtual Key

```bash
curl -X POST 'https://<domain>/key/generate' \
  -H 'Authorization: Bearer <MASTER_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{
    "key_alias": "team-a-key",
    "models": ["gpt-4o", "bedrock-claude-sonnet"],
    "max_budget": 100.0,
    "budget_duration": "1mo",
    "max_parallel_requests": 10,
    "tpm_limit": 100000,
    "rpm_limit": 500
  }'
```

### 创建团队

```bash
curl -X POST 'https://<domain>/team/new' \
  -H 'Authorization: Bearer <MASTER_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{
    "team_alias": "engineering",
    "max_budget": 500.0,
    "budget_duration": "1mo",
    "models": ["gpt-4o", "bedrock-claude-sonnet"]
  }'
```

### 管理操作

| 操作 | API | 方法 |
|------|-----|------|
| 查看 Key 信息 | `/key/info` | GET |
| 列出所有 Key | `/key/list` | GET |
| 更新 Key | `/key/update` | POST |
| 删除 Key | `/key/delete` | POST |
| 查看团队 | `/team/list` | GET |
| 更新团队 | `/team/update` | POST |

---

## 10. 健康检查与连接测试

### 内置端点

```bash
# 存活检查（ALB/ECS 用）
curl https://<domain>/health/liveliness

# 就绪检查（含 DB、Redis、模型状态）
curl https://<domain>/health/readiness

# 最新健康状态
curl -H "Authorization: Bearer <MASTER_KEY>" \
  https://<domain>/health/latest

# 测试特定模型连接
curl -X POST https://<domain>/health/test_connection \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"litellm_model_id": "<model-uuid>"}'
```

### 模型列表查询

```bash
# 查看所有可用模型
curl -H "Authorization: Bearer <MASTER_KEY>" \
  https://<domain>/v1/models

# 查看特定模型详情
curl -H "Authorization: Bearer <MASTER_KEY>" \
  https://<domain>/v1/model/info?litellm_model_id=<uuid>
```

---

## 11. 踩坑记录与最佳实践

### 踩坑 1: UI 添加 Bedrock 模型导致调用失败

**现象：** 通过 UI Model Management 添加的 Bedrock 模型，测试连接不通过。

**错误信息：**
```
BedrockException - {"message":"The model returned the following errors:
  vector_store_ids: Extra inputs are not permitted"}
```

**根因：** LiteLLM v1.82.x 的 UI 在添加模型时，自动在 `litellm_params` 中注入 `vector_store_ids: []`、`guardrails: []`、`tags: []` 等字段。这些字段被原样传递给 Bedrock API，而 Bedrock 不接受这些额外字段。

**解决：**
1. 通过 API 删除 DB 中的问题模型
2. 改为在 config.yaml 中配置（干净，无多余字段）

```bash
# 删除 DB 模型
curl -X POST https://<domain>/model/delete \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"id": "<model-uuid>"}'
```

**教训：Bedrock 模型务必通过 config.yaml 配置，不要用 UI。**

---

### 踩坑 2: `drop_params: true` 不能解决所有问题

`drop_params` 仅丢弃模型调用时的 API 参数（如 `frequency_penalty`），**不会清理 `litellm_params` 中存储的元数据字段**（如 `vector_store_ids`）。

---

### 踩坑 3: Bedrock 模型 ID 的版本号

有些模型 ID 需要完整版本号（`:0`），有些不需要：

```yaml
# 需要版本号
model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0    # 正确
model: bedrock/anthropic.claude-sonnet-4-20250514-v1:0         # 正确

# 不需要版本号（较新模型）
model: bedrock/us.anthropic.claude-opus-4-6-v1                  # 正确
model: bedrock/us.anthropic.claude-sonnet-4-6                   # 正确
```

**建议：** 用 `aws bedrock list-foundation-models` 确认官方 ID，直接复制。

---

### 踩坑 4: ECS 网络连通性

Bedrock 模型在 ECS Private Subnet 中调用，需要确保：
- NAT Gateway 存在（Fargate 通过 NAT 访问公网 API）
- 安全组允许 443 出站流量
- ECS Task Role 有 `bedrock:InvokeModel` 权限

---

### 最佳实践总结

| # | 实践 | 说明 |
|---|------|------|
| 1 | Bedrock 模型用 config.yaml | 避免 UI 注入多余字段的 bug |
| 2 | 开启 `drop_params: true` | 多 Provider 兼容性保障 |
| 3 | 密钥用 `os.environ/` | 禁止硬编码，用 Secrets Manager 注入 |
| 4 | 跨区域推理用 `us.` 前缀 | 高可用，自动故障转移 |
| 5 | 配置变更走 S3 + 重部署 | IaC 流程，可回滚 |
| 6 | 开启 Redis 缓存 | 多副本共享，降低 API 成本 |
| 7 | 审计日志写 DynamoDB | 开启 TTL，控制存储成本 |
| 8 | 用 `model_name` 做抽象 | 用户调 `gpt-4`，后端可换 Provider |
| 9 | ALB 健康检查用 `/health/liveliness` | 轻量，不触发模型调用 |
| 10 | 修改配置后验证调用 | `curl /v1/chat/completions` 确认可用 |

---

## 12. 完整配置示例

以下是本项目的生产配置：

```yaml
model_list:
  # --- OpenAI ---
  - model_name: gpt-4o
    litellm_params:
      model: openai/gpt-4o
      api_key: os.environ/OPENAI_API_KEY

  - model_name: gpt-4o-mini
    litellm_params:
      model: openai/gpt-4o-mini
      api_key: os.environ/OPENAI_API_KEY

  - model_name: gpt-4.1
    litellm_params:
      model: openai/gpt-4.1
      api_key: os.environ/OPENAI_API_KEY

  # --- Anthropic（直连 API） ---
  - model_name: claude-sonnet-4-20250514
    litellm_params:
      model: anthropic/claude-sonnet-4-20250514
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: claude-haiku-4-5-20251001
    litellm_params:
      model: anthropic/claude-haiku-4-5-20251001
      api_key: os.environ/ANTHROPIC_API_KEY

  # --- AWS Bedrock（IAM Task Role 认证，无需 API Key） ---
  - model_name: bedrock-claude-opus
    litellm_params:
      model: bedrock/us.anthropic.claude-opus-4-6-v1
      aws_region_name: us-east-1

  - model_name: bedrock-claude-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_region_name: us-east-1

  - model_name: bedrock-claude-haiku
    litellm_params:
      model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
      aws_region_name: us-east-1

  # --- Google Gemini ---
  - model_name: gemini-2.0-flash
    litellm_params:
      model: gemini/gemini-2.0-flash
      api_key: os.environ/GEMINI_API_KEY

  - model_name: gemini-2.5-pro
    litellm_params:
      model: gemini/gemini-2.5-pro-preview-05-06
      api_key: os.environ/GEMINI_API_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  store_model_in_db: true

litellm_settings:
  num_retries: 3
  request_timeout: 600
  set_verbose: false
  drop_params: true
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    ssl: true
  success_callback: ["dynamodb"]
  failure_callback: ["dynamodb"]
  dynamodb_table_name: litellm-gw-audit-log
```

### 部署流程

```bash
# 1. 编辑配置
vim config/litellm-config.yaml

# 2. 上传到 S3
aws s3 cp config/litellm-config.yaml \
  s3://litellm-gw-config-284367710968/litellm-config.yaml

# 3. 滚动更新 ECS
aws ecs update-service \
  --cluster litellm-gw-cluster \
  --service litellm-gw-service \
  --force-new-deployment \
  --region us-east-1

# 4. 验证部署完成
aws ecs describe-services \
  --cluster litellm-gw-cluster \
  --services litellm-gw-service \
  --region us-east-1 \
  --query 'services[0].deployments[*].{status:status,running:runningCount,rollout:rolloutState}'

# 5. 验证模型可用
MASTER_KEY="your-master-key"
curl -s -X POST "https://d2cyolr4rt91j1.cloudfront.net/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "bedrock-claude-sonnet", "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 10}'
```

---

## 参考链接

- [LiteLLM 官方文档](https://docs.litellm.ai/)
- [LiteLLM GitHub](https://github.com/BerriAI/litellm)
- [Supported Providers](https://docs.litellm.ai/docs/providers)
- [Proxy Server Quick Start](https://docs.litellm.ai/docs/proxy/quick_start)
- [AWS Bedrock 模型列表](https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html)
- [Bedrock Cross-Region Inference](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html)
