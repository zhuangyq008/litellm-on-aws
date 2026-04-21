# LiteLLM 审计日志管道

## 概述

本项目实现了一套完整的 LLM API 调用审计日志系统，从 DynamoDB 实时流采集，经 Lambda 转换写入 S3，通过 Glue + Athena 提供 SQL 查询能力，最终由 React SPA 呈现给管理员。

```
LiteLLM (ECS)
  │  写入审计记录
  ▼
DynamoDB (litellm-gw-audit-log)
  │  DynamoDB Streams (NEW_IMAGE)
  ▼
Lambda (stream-processor)
  │  解析 + 转换 → NDJSON
  ▼
S3 (litellm-gw-audit-{AccountId}/logs/)
  │  Hive 分区: year=YYYY/month=MM/day=DD
  ▼
Glue Catalog (litellm_gw_audit.audit_logs)
  │  Partition Projection (免维护分区)
  ▼
Athena Workgroup (litellm-gw-audit)
  │
  ▼
API Gateway + Lambda (query-api)
  │  Cognito JWT 认证
  ▼
React SPA (CloudFront + S3)
```

---

## CloudFormation Stack 及部署顺序

| 顺序 | Stack 名称 | 模板文件 | 核心资源 |
|------|-----------|---------|---------|
| 1 | litellm-gw-vpc | cfn/01-vpc.yaml | VPC、子网 |
| 2 | litellm-gw-secrets | cfn/02-secrets.yaml | Secrets Manager |
| 3 | litellm-gw-data | cfn/03-data.yaml | RDS、Redis、**DynamoDB audit-log 表**、S3 Config |
| 4 | litellm-gw-ecs | cfn/04-ecs.yaml | ECS 服务 (LiteLLM 写入审计表) |
| 5 | litellm-gw-cloudfront | cfn/05-cloudfront.yaml | LiteLLM 网关 CloudFront |
| 6 | litellm-gw-audit-pipeline | cfn/06-audit-pipeline.yaml | S3 审计桶、Stream Lambda、Glue、Athena |
| 7 | litellm-gw-audit-ui | cfn/07-audit-ui.yaml | Cognito、API Gateway、Query Lambda、SPA 桶、CloudFront |

Stack 间通过 CloudFormation Export/Import 传递依赖（如 DynamoDB Stream ARN、S3 Bucket ARN 等）。

---

## DynamoDB 审计日志表

定义在 `cfn/03-data.yaml`，表名 `litellm-gw-audit-log`。

| 配置项 | 值 |
|-------|---|
| 分区键 (HASH) | `id` (String) - 请求唯一 ID |
| 排序键 (RANGE) | `startTime` (String) - 时间戳 |
| 计费模式 | PAY_PER_REQUEST (按需) |
| Stream | `NEW_IMAGE` (仅捕获新记录状态) |
| TTL | `ttl` 属性 (Unix 时间戳自动过期) |
| PITR | 已启用 |

LiteLLM 写入的每条记录包含以下字段：

| 字段 | 类型 | 说明 |
|------|------|------|
| id | String | 请求 UUID |
| startTime | String | 调用开始时间 |
| endTime | String | 调用结束时间 |
| call_type | String | 如 `anthropic_messages` |
| model | String | 如 `us.anthropic.claude-opus-4-6-v1` |
| messages | String | Python list repr (原始消息) |
| response | String | LiteLLM ModelResponse repr |
| usage | String | LiteLLM Usage repr |
| metadata | String | Python dict repr (含 headers、user_id 等) |
| modelParameters | String | Python dict repr |
| ttl | Number | Unix 时间戳 |

---

## Stream Processor Lambda

**函数名**: `litellm-gw-stream-processor`
**源码**: `lambda/stream-processor/handler.py` + `parser.py`
**运行时**: Python 3.12 | 内存 256MB | 超时 60s

### 事件源配置

| 参数 | 值 | 说明 |
|------|---|------|
| StartingPosition | TRIM_HORIZON | 从流的最早记录开始 |
| BatchSize | 100 | 每批最多 100 条记录 |
| MaximumBatchingWindowInSeconds | 60 | 等待最多 60 秒凑批 |

### 处理逻辑

1. 过滤 `INSERT` 和 `MODIFY` 事件（跳过 `REMOVE`）
2. 对每条记录调用 `transform_record()` 提取结构化字段
3. 成功记录序列化为 NDJSON，写入 `s3://bucket/logs/year=YYYY/month=MM/day=DD/{timestamp}-{batch_id}.json`
4. 失败记录写入 `s3://bucket/errors/` 同样的分区路径

### 数据转换 (parser.py)

`transform_record()` 将 DynamoDB Stream 格式（`{"S": "value"}`）转换为扁平 JSON：

| 解析函数 | 输入 | 输出字段 |
|---------|------|---------|
| `parse_usage()` | Usage repr 字符串 | completion_tokens, prompt_tokens, total_tokens, cached_tokens, reasoning_tokens |
| `parse_response()` | ModelResponse repr | finish_reason, response_preview (截取 500 字符), has_tool_calls, tool_names |
| `parse_messages()` | messages list repr | message_count, user_message_preview (最后一条 user 消息, 截取 500 字符) |
| `parse_metadata()` | metadata dict repr | device_id, session_id, source_ip (从 x-forwarded-for 提取) |

原始字段 `raw_messages`, `raw_response`, `raw_metadata`, `raw_model_parameters` 也会保留，用于详情查看。

---

## S3 分区策略

**桶名**: `litellm-gw-audit-{AccountId}`

```
s3://litellm-gw-audit-{AccountId}/
├── logs/                          # 审计日志 (90 天自动删除)
│   └── year=2026/
│       └── month=04/
│           └── day=20/
│               └── 1713607200000-a1b2c3d4.json
├── errors/                        # 处理失败记录 (180 天自动删除)
│   └── year=2026/...
└── athena-results/                # Athena 查询结果 (7 天自动删除)
```

分区键从 DynamoDB 记录的 `startTime` 提取；如果解析失败则用当前 UTC 时间。文件名格式: `{unix_ms}-{8位随机ID}.json`。

### S3 生命周期规则

| 前缀 | 过期天数 | 用途 |
|------|---------|------|
| `logs/` | 90 天 | 审计日志主数据 |
| `errors/` | 180 天 | 错误记录保留更久用于排查 |
| `athena-results/` | 7 天 | 查询临时结果 |

---

## Glue 表 & Partition Projection

定义在 `cfn/06-audit-pipeline.yaml`。

**数据库**: `litellm_gw_audit`
**表名**: `audit_logs`
**格式**: JSON (SerDe: `org.openx.data.jsonserde.JsonSerDe`)

### 表结构 (19 列 + 3 分区键)

```
── 基本信息 ──────────────────────────
id                    STRING
call_type             STRING
model                 STRING
start_time            STRING
end_time              STRING

── Token 统计 ────────────────────────
completion_tokens     BIGINT
prompt_tokens         BIGINT
total_tokens          BIGINT
cached_tokens         BIGINT
reasoning_tokens      BIGINT

── 响应信息 ──────────────────────────
finish_reason         STRING
response_preview      STRING
has_tool_calls        BOOLEAN
tool_names            ARRAY<STRING>

── 消息信息 ──────────────────────────
message_count         INT
user_message_preview  STRING

── 客户端信息 ────────────────────────
device_id             STRING
session_id            STRING
source_ip             STRING

── 原始数据 (详情查看) ───────────────
raw_messages          STRING
raw_response          STRING
raw_metadata          STRING
raw_model_parameters  STRING

── 分区键 ────────────────────────────
year                  STRING
month                 STRING
day                   STRING
```

### Partition Projection 配置

使用 Athena Partition Projection 自动推断分区，无需运行 `MSCK REPAIR TABLE`：

```yaml
projection.enabled: "true"
projection.year.type: integer
projection.year.range: "2026,2030"
projection.month.type: integer
projection.month.range: "1,12"
projection.month.digits: "2"
projection.day.type: integer
projection.day.range: "1,31"
projection.day.digits: "2"
storage.location.template: s3://{bucket}/logs/year=${year}/month=${month}/day=${day}
```

查询时 Athena 根据 WHERE 条件中的 year/month/day 自动裁剪分区，仅扫描必要的 S3 路径。

---

## Query API

**函数名**: `litellm-gw-query-api`
**源码**: `lambda/query-api/handler.py` + `query_builder.py`
**运行时**: Python 3.12 | 内存 256MB | 超时 30s

### API 端点

所有端点通过 API Gateway + Cognito Authorizer 保护，需在 `Authorization` 头传入 idToken。

#### 1. 提交查询

```
POST /api/query
```

请求体：

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
  "page_size": 50
}
```

- `start_date` 和 `end_date` 必填，格式 `YYYY-MM-DD`
- 其他过滤条件均可选
- `keyword` 模糊搜索 `user_message_preview` 和 `response_preview`
- `page_size` 默认 50，最大 200

响应：

```json
{ "execution_id": "abc-def-ghi-123" }
```

#### 2. 获取查询结果

```
GET /api/query/{execution_id}
```

响应（查询中）：

```json
{ "status": "RUNNING" }
```

响应（成功）：

```json
{
  "status": "SUCCEEDED",
  "results": [ { "id": "...", "model": "...", ... } ],
  "count": 42
}
```

响应（失败）：

```json
{ "status": "FAILED", "error": "..." }
```

#### 3. 获取单条记录详情

```
GET /api/record/{record_id}
```

同步查询，最长等待 30 秒。返回包含所有字段（含 raw_* 原始数据）的完整记录。

### SQL 注入防护

`query_builder.py` 采用多层防护：

1. **日期格式校验**: 正则 `^\d{4}-\d{2}-\d{2}$` 强制 YYYY-MM-DD
2. **`_sanitize()` 函数**: 移除 `;` `'` `\` `--` 以及 DROP/DELETE/INSERT/UPDATE/UNION/SELECT 等关键词
3. **分区过滤生成**: 动态计算 year/month 范围，避免全表扫描
4. **整数强转**: `min_total_tokens` 和 `page_size` 通过 `int()` 转换

### 生成的 SQL 示例

```sql
SELECT id, call_type, model, start_time, end_time,
       completion_tokens, prompt_tokens, total_tokens, cached_tokens, reasoning_tokens,
       finish_reason, response_preview, has_tool_calls, tool_names,
       message_count, user_message_preview, device_id, session_id, source_ip
FROM "litellm_gw_audit".audit_logs
WHERE year = '2026' AND month = '04'
  AND start_time >= '2026-04-01'
  AND start_time < '2026-04-20'
  AND model = 'us.anthropic.claude-opus-4-6-v1'
ORDER BY start_time DESC
LIMIT 50
```

---

## Cognito 认证 & UI 层

### Cognito 配置

| 配置项 | 值 |
|-------|---|
| 用户池名 | litellm-gw-audit-userpool |
| 自注册 | 禁用（仅管理员创建用户） |
| 用户名属性 | email |
| 密码策略 | 8+ 字符，大小写 + 数字 + 特殊字符 |
| 认证流程 | USER_SRP_AUTH, USER_PASSWORD_AUTH, REFRESH_TOKEN |
| Access Token 有效期 | 1 小时 |
| Refresh Token 有效期 | 30 天 |

### React SPA

- **框架**: Vite + React + Tailwind CSS
- **认证库**: amazon-cognito-identity-js (SRP 认证)
- **部署**: S3 + CloudFront (OAC)
- **路由**: CloudFront 将 403/404 重定向到 /index.html (SPA 路由)

构建时环境变量注入（Vite `import.meta.env`）：

```
VITE_API_ENDPOINT     → API Gateway 端点
VITE_COGNITO_USER_POOL_ID → Cognito 用户池 ID
VITE_COGNITO_CLIENT_ID    → Cognito 客户端 ID
VITE_COGNITO_DOMAIN       → Cognito 域名
```

---

## 部署步骤

### 全量部署

运行 `deploy.sh` 会按顺序部署所有 7 个 Stack 并构建 SPA。

```bash
./deploy.sh
```

### 仅更新审计管道

```bash
# 1. 打包 Lambda 函数
cd lambda/stream-processor && zip -r /tmp/stream-processor.zip handler.py parser.py && cd -
cd lambda/query-api && zip -r /tmp/query-api.zip handler.py query_builder.py && cd -

# 2. 上传到 S3
CONFIG_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name litellm-gw-data --query 'Stacks[0].Outputs[?OutputKey==`ConfigBucketName`].OutputValue' --output text)

aws s3 cp /tmp/stream-processor.zip "s3://${CONFIG_BUCKET}/lambda/stream-processor.zip"
aws s3 cp /tmp/query-api.zip "s3://${CONFIG_BUCKET}/lambda/query-api.zip"

# 3. 更新 CFN Stack (触发 Lambda 代码更新)
aws cloudformation update-stack \
  --stack-name litellm-gw-audit-pipeline \
  --template-body file://cfn/06-audit-pipeline.yaml \
  --capabilities CAPABILITY_NAMED_IAM

aws cloudformation update-stack \
  --stack-name litellm-gw-audit-ui \
  --template-body file://cfn/07-audit-ui.yaml \
  --capabilities CAPABILITY_NAMED_IAM
```

### 仅更新前端

```bash
cd audit-ui

# 获取环境变量
AUDIT_API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' --output text)
COGNITO_POOL_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoUserPoolId`].OutputValue' --output text)
COGNITO_CLIENT_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoClientId`].OutputValue' --output text)
COGNITO_DOMAIN=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui \
  --query 'Stacks[0].Outputs[?OutputKey==`CognitoDomain`].OutputValue' --output text)

VITE_API_ENDPOINT="$AUDIT_API_ENDPOINT" \
VITE_COGNITO_USER_POOL_ID="$COGNITO_POOL_ID" \
VITE_COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN" \
npm run build

SPA_BUCKET=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaBucketName`].OutputValue' --output text)
SPA_CF_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-audit-ui \
  --query 'Stacks[0].Outputs[?OutputKey==`SpaCloudFrontDistributionId`].OutputValue' --output text)

aws s3 sync dist/ "s3://${SPA_BUCKET}/" --delete
aws cloudfront create-invalidation --distribution-id "$SPA_CF_ID" --paths "/*"
```

### 创建 Cognito 管理员

```bash
aws cognito-idp admin-create-user \
  --user-pool-id <UserPoolId> \
  --username admin@example.com \
  --temporary-password 'TempPass123!' \
  --user-attributes Name=email,Value=admin@example.com Name=email_verified,Value=true
```

首次登录会要求修改密码。

---

## 监控 & 排障

### CloudWatch 日志

| Lambda | 日志组 |
|--------|-------|
| stream-processor | /aws/lambda/litellm-gw-stream-processor |
| query-api | /aws/lambda/litellm-gw-query-api |

### 关键指标

| 指标 | 来源 | 关注点 |
|------|------|-------|
| Stream 处理延迟 | stream-processor 日志 | `processed` vs `errors` 计数 |
| Athena 查询耗时 | Athena Workgroup CloudWatch | 超过 10 秒需优化查询范围 |
| Athena 扫描量 | Athena Workgroup CloudWatch | 直接影响成本 |
| API 4xx/5xx 错误 | API Gateway 日志 | 认证或查询参数问题 |

### 常见问题

#### Stream Processor 没有处理数据

1. 检查 DynamoDB Stream 是否启用: `aws dynamodb describe-table --table-name litellm-gw-audit-log --query 'Table.StreamSpecification'`
2. 检查 Event Source Mapping 状态: `aws lambda list-event-source-mappings --function-name litellm-gw-stream-processor`
3. 查看 Lambda 日志中的错误

#### Athena 查询返回空结果

1. 确认 S3 中有数据: `aws s3 ls s3://litellm-gw-audit-{AccountId}/logs/ --recursive | head`
2. 确认查询日期范围匹配 S3 分区
3. 在 Athena 控制台直接运行: `SELECT count(*) FROM "litellm_gw_audit".audit_logs WHERE year='2026' AND month='04'`

#### 前端登录报 USER_SRP_AUTH 错误

确保 `cfn/07-audit-ui.yaml` 中 `ExplicitAuthFlows` 包含 `ALLOW_USER_SRP_AUTH`，并重新部署 Stack。

#### CORS 错误

确保 API Gateway 中:
- `/api/query` 和 `{proxy+}` 资源都有 OPTIONS 方法
- `GatewayResponse4xx` 和 `GatewayResponse5xx` 设置了 CORS 头
- Lambda 响应中包含 `Access-Control-Allow-Origin: *`

---

## 项目文件索引

| 文件 | 用途 |
|------|------|
| cfn/03-data.yaml | DynamoDB 审计日志表定义 |
| cfn/06-audit-pipeline.yaml | S3 桶、Stream Lambda、Glue、Athena |
| cfn/07-audit-ui.yaml | Cognito、API Gateway、Query Lambda、SPA 基础设施 |
| lambda/stream-processor/handler.py | Stream 处理器入口 |
| lambda/stream-processor/parser.py | DynamoDB 记录解析与转换 |
| lambda/query-api/handler.py | 查询 API 入口 (路由分发) |
| lambda/query-api/query_builder.py | Athena SQL 构建与注入防护 |
| audit-ui/ | React SPA (Vite + Tailwind) |
| deploy.sh | 全量部署脚本 |
