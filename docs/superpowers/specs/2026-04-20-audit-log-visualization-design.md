# Audit Log Visualization & Query System — Design Spec

## Overview

为 LiteLLM Gateway 构建类 CloudTrail 的审计日志查询系统。当前审计日志存储在 DynamoDB，仅支持 AWS CLI 查询。本设计将数据流向 S3，通过 Athena 提供 SQL 查询能力，并构建带 Cognito 认证的 Web UI 供管理团队使用。

## Architecture

```
LiteLLM (ECS) → DynamoDB (audit-log)
                    ↓ DynamoDB Streams
               Lambda (stream-to-s3)
                    ↓ NDJSON
               S3 (审计桶, year/month/day 分区)
                    ↓ Glue Catalog
               Athena (SQL 查询)
                    ↑ API Gateway + Lambda (Query API)
               Cognito (管理员认证)
                    ↑
               SPA (S3 + CloudFront)
```

## 1. Data Pipeline

### 1.1 DynamoDB Streams

修改现有 `03-data.yaml`，为 `AuditLogTable` 启用 Streams：

```yaml
StreamSpecification:
  StreamViewType: NEW_IMAGE
```

### 1.2 Stream Processor Lambda

- **运行时**: Python 3.12
- **内存**: 256MB
- **超时**: 60s
- **触发器**: DynamoDB Streams, BatchSize 100, MaximumBatchingWindowInSeconds 60

**处理流程:**

1. 接收 DynamoDB Stream batch event
2. 遍历每条 INSERT/MODIFY 记录
3. 解析各字段：`messages`、`metadata`、`modelParameters` 使用 `ast.literal_eval`（标准 Python dict/list 格式）；`response` 和 `usage` 是 LiteLLM 对象的 repr 字符串（如 `ModelResponse(...)`、`Usage(...)`），需用正则表达式提取关键值（finish_reason、content、token counts 等）
4. 提取结构化字段（见 1.4 节）
5. 截断大字段（preview 字段 ≤ 500 字符）
6. 原始字段序列化为 JSON string（raw_* 字段）
7. 组装 NDJSON，写入 S3
8. 解析失败的记录写入 `errors/` 前缀

**S3 输出路径:**

```
s3://litellm-gw-audit-{AccountId}/
  logs/year=2026/month=04/day=20/{timestamp}-{batch_id}.json
  errors/year=2026/month=04/day=20/{timestamp}-{batch_id}.json
```

### 1.3 S3 Audit Bucket

- **桶名**: `litellm-gw-audit-{AccountId}`
- **加密**: SSE-S3
- **版本控制**: 关闭
- **Lifecycle Policy**:
  - `logs/` 前缀: 90 天后删除
  - `errors/` 前缀: 180 天后删除
  - `athena-results/` 前缀: 7 天后删除

### 1.4 Athena Table Schema

通过 Glue Catalog 定义：

```sql
CREATE EXTERNAL TABLE audit_logs (
  -- 基础字段
  id                    STRING,
  call_type             STRING,
  model                 STRING,
  start_time            STRING,
  end_time              STRING,

  -- usage 提取
  completion_tokens     BIGINT,
  prompt_tokens         BIGINT,
  total_tokens          BIGINT,
  cached_tokens         BIGINT,
  reasoning_tokens      BIGINT,

  -- response 提取
  finish_reason         STRING,
  response_preview      STRING,
  has_tool_calls        BOOLEAN,
  tool_names            ARRAY<STRING>,

  -- messages 提取
  message_count         INT,
  user_message_preview  STRING,

  -- metadata 提取
  device_id             STRING,
  session_id            STRING,
  source_ip             STRING,

  -- 原始数据（按需查看）
  raw_messages          STRING,
  raw_response          STRING,
  raw_metadata          STRING,
  raw_model_parameters  STRING
)
PARTITIONED BY (year STRING, month STRING, day STRING)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
LOCATION 's3://litellm-gw-audit-{AccountId}/logs/'
```

**Athena Workgroup:**
- Name: `litellm-gw-audit`
- 结果输出: `s3://litellm-gw-audit-{AccountId}/athena-results/`

## 2. Query API

### 2.1 API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/query` | 提交审计日志查询，返回 `{ execution_id }` |
| GET | `/api/query/{execution-id}` | 获取查询结果（轮询），返回 `{ status, results }` |
| GET | `/api/record/{id}` | 获取单条记录详情（含 raw_* 原始数据） |

### 2.2 Query Parameters (POST /api/query)

```json
{
  "start_date": "2026-04-01",
  "end_date": "2026-04-20",
  "model": "us.anthropic.claude-opus-4-6-v1",
  "call_type": "anthropic_messages",
  "session_id": "f61cee15-...",
  "device_id": "8d6ae821...",
  "source_ip": "44.219.177.250",
  "finish_reason": "stop",
  "min_total_tokens": 1000,
  "has_tool_calls": true,
  "keyword": "error",
  "page_size": 50,
  "next_token": "..."
}
```

- Lambda 根据查询条件动态构建 Athena SQL，使用参数化查询防 SQL 注入
- 时间范围自动映射到分区裁剪（`WHERE year='2026' AND month='04'`）

### 2.3 Query Lambda

- **运行时**: Python 3.12
- **内存**: 256MB
- **超时**: 30s
- **环境变量**: `ATHENA_DATABASE`, `ATHENA_TABLE`, `ATHENA_WORKGROUP`, `S3_OUTPUT_LOCATION`

### 2.4 API Gateway

- REST API with Cognito Authorizer
- 仅接受 Cognito 认证 Token

## 3. Authentication

### 3.1 Cognito User Pool

| Config | Value |
|--------|-------|
| Pool Name | `litellm-gw-audit-userpool` |
| App Client | SPA (public client, no client secret) |
| Auth Flow | Hosted UI → Authorization Code + PKCE |
| Self-Registration | Disabled (管理员手动创建账号) |
| Password Policy | 8+, uppercase + lowercase + digits + special chars |
| Access Token TTL | 1 hour |
| Refresh Token TTL | 30 days |

### 3.2 Auth Flow

```
用户访问 SPA → 未登录 → 跳转 Cognito Hosted UI
  → 输入账号密码 → 认证成功
  → 回调 SPA (Authorization Code)
  → SPA 用 Code + PKCE 换 Access Token
  → 后续请求携带 Access Token 调用 API Gateway
  → API Gateway Cognito Authorizer 验证 Token
```

能登录即为管理员，无需用户组/角色区分。

## 4. Web UI

### 4.1 Technology

- **Framework**: React + Vite
- **Styling**: Tailwind CSS
- **Auth**: amazon-cognito-identity-js
- **Deployment**: S3 静态托管 + 独立 CloudFront Distribution

### 4.2 Pages

**Main Page — 审计日志列表:**

- 顶部筛选栏（两行）:
  - 常用: Time Range, Model, Call Type, Session ID, Finish Reason, Search 按钮
  - 高级: Device ID, Source IP, Min Tokens, Has Tool Calls checkbox, Keyword
- 中间结果表格:
  - 列: Time, Model, Type, Finish Reason, Tokens, Tools, User Message Preview
  - 行点击展开详情
  - 失败/异常行红色背景高亮
- 底部分页: 50 条/页

**Detail Panel — 记录详情 (点击行展开):**

- 9 宫格摘要: Model, Time, Duration, Tokens (In/Out/Total), Cached Tokens, Finish Reason, Session ID, Device ID, Tools Called
- Tab 切换:
  - User Message — 用户最后一条消息
  - Response — 助手回复内容
  - Raw Request — 完整原始请求 JSON
  - Raw Response — 完整原始响应 JSON

## 5. Infrastructure (CloudFormation)

### 5.1 New Stacks

融入现有 5 stack 体系：

| Order | Stack Name | Resources |
|-------|-----------|-----------|
| 06 | `litellm-gw-audit-pipeline` | Stream Lambda, S3 审计桶, S3 Lifecycle Policy, Glue Database + Table, Athena Workgroup, IAM Roles |
| 07 | `litellm-gw-audit-ui` | Cognito User Pool + App Client, API Gateway + Cognito Authorizer, Query Lambda, S3 SPA 桶, CloudFront Distribution |

### 5.2 Modifications to Existing Stacks

- `03-data.yaml`: 给 AuditLogTable 添加 `StreamSpecification: StreamViewType: NEW_IMAGE`，导出 Stream ARN

### 5.3 Key Resource Config

```
Stream Lambda:
  Runtime: python3.12, Memory: 256MB, Timeout: 60s
  Trigger: DynamoDB Streams, BatchSize: 100, MaxBatchingWindow: 60s

Query Lambda:
  Runtime: python3.12, Memory: 256MB, Timeout: 30s

S3 Audit Bucket:
  Encryption: SSE-S3, Versioning: Disabled
  Lifecycle: logs/ 90d, errors/ 180d, athena-results/ 7d

Athena Workgroup:
  Name: litellm-gw-audit
  Output: s3://litellm-gw-audit-{AccountId}/athena-results/
```

## 6. Data Retention

| Storage | Retention | Mechanism |
|---------|-----------|-----------|
| DynamoDB | TTL-based (existing) | TTL attribute |
| S3 logs/ | 90 days | Lifecycle Policy |
| S3 errors/ | 180 days | Lifecycle Policy |
| S3 athena-results/ | 7 days | Lifecycle Policy |

## 7. Security

- Web UI 仅管理团队访问，Cognito 关闭自注册
- API Gateway 所有端点通过 Cognito Authorizer 保护
- Query Lambda 使用参数化查询，防止 SQL 注入
- S3 桶启用 SSE-S3 加密
- 所有 Lambda 遵循最小权限原则（IAM Policy）
- CloudFront 配合 OAC 访问 S3 SPA 桶

## 8. Cost Estimate (Low Traffic)

| Service | Estimated Monthly Cost |
|---------|----------------------|
| DynamoDB Streams | Free (included with DynamoDB) |
| Lambda (Stream) | < $1 (low invocation count) |
| S3 Storage (90d logs) | < $1 (small data volume) |
| Athena Queries | $5/TB scanned, minimal for filtered queries |
| Lambda (Query API) | < $1 |
| API Gateway | < $1 |
| Cognito | Free tier (< 50k MAU) |
| CloudFront (SPA) | < $1 |
| **Total** | **~$5-10/month** |
