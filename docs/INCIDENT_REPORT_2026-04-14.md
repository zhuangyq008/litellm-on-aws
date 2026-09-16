# LiteLLM Gateway 4xx 错误率异常 — 故障报告

**日期**: 2026-04-14  
**严重程度**: P1 (服务部分不可用)  
**影响范围**: Claude Code 通过 LiteLLM Gateway 调用子代理 (Subagent) 时约 80% 的请求失败  
**状态**: 已修复

---

## 1. 问题概述

CloudFront 监控显示 4xx 错误率持续在 **78%~92%** 之间，远超正常阈值 (< 10%)。通过 CloudWatch 指标和 ECS 应用日志分析，确认大量 `POST /v1/messages` 请求返回 **401 Unauthorized**。

| 指标 | 异常值 | 正常阈值 |
|------|--------|----------|
| 4xx 错误率 | 78% ~ 92% | < 10% |
| 5xx 错误率 | 0% | < 1% |
| Origin 延迟 (Avg) | 2.5s | < 10s |

> 注: 5xx 为零且 Origin 延迟正常，排除了基础设施层面的故障。

---

## 2. 根因分析

故障由 **两层配置不匹配** 叠加导致：

### 2.1 Team 模型权限不完整

LiteLLM 的 Virtual Key 通过 Team 进行模型访问控制。当前 "Dev" Team 仅配置了 3 个模型名称的访问权限：

| Team 允许的模型名 | 说明 |
|---|---|
| `bedrock-claude-opus` | Bedrock Opus |
| `bedrock-claude-haiku` | Bedrock Haiku |
| `global.anthropic.claude-sonnet-4-6` | 名称配置有误 |

而 Claude Code 的子代理系统 (Subagent) 在执行 WebFetch、代码搜索等辅助操作时，会自动使用 Anthropic **原生模型名称**发起请求，例如：

- `claude-haiku-4-5-20251001`
- `claude-sonnet-4-20250514`

这些名称不在 Team 的允许列表中，导致 LiteLLM 返回：

```json
{
  "error": {
    "message": "team not allowed to access model",
    "type": "team_model_access_denied",
    "code": "401"
  }
}
```

### 2.2 模型路由配置错误

`litellm-config.yaml` 中同时定义了 Anthropic 直连路由和 Bedrock 路由：

```yaml
# 直连 Anthropic API (存在问题)
- model_name: claude-haiku-4-5-20251001
  litellm_params:
    model: anthropic/claude-haiku-4-5-20251001
    api_key: os.environ/ANTHROPIC_API_KEY      # 该 Key 已失效

# Bedrock 路由 (正常)
- model_name: bedrock-claude-haiku
  litellm_params:
    model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
    aws_region_name: us-east-1                 # 通过 IAM Role 认证
```

当请求中指定 `model: claude-haiku-4-5-20251001` 时，LiteLLM 优先匹配到 Anthropic 直连路由，使用已失效的 API Key 发起请求，导致 Anthropic 返回 `authentication_error: invalid x-api-key`。

### 2.3 故障链路

```
Claude Code Subagent
  → 发送请求 model: "claude-haiku-4-5-20251001"
    → [关卡1] LiteLLM Team 权限检查: 模型名不在允许列表 → 401
    → [关卡2] 即使通过权限检查，路由到 Anthropic 直连 API → API Key 失效 → 401
```

两层问题叠加，导致所有使用原生模型名的子代理请求全部失败。

---

## 3. 修复措施

### 3.1 统一模型路由至 AWS Bedrock

移除 Anthropic 直连路由定义，为 Anthropic 原生模型名称添加 Bedrock 路由映射：

```yaml
# 修复后: 原生模型名直接路由到 Bedrock
- model_name: claude-haiku-4-5-20251001
  litellm_params:
    model: bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0
    aws_region_name: us-east-1

- model_name: claude-sonnet-4-20250514
  litellm_params:
    model: bedrock/us.anthropic.claude-sonnet-4-6
    aws_region_name: us-east-1

- model_name: claude-opus-4-6
  litellm_params:
    model: bedrock/us.anthropic.claude-opus-4-6-v1
    aws_region_name: us-east-1
```

**优势**: Bedrock 通过 ECS Task Role 的 IAM 凭证进行认证，无需管理 API Key，不存在 Key 过期问题。

### 3.2 扩展 Team 模型访问权限

更新 "Dev" Team 的模型允许列表，覆盖所有 Bedrock 别名和 Anthropic 原生模型名：

```
bedrock-claude-opus, bedrock-claude-sonnet, bedrock-claude-haiku,
claude-opus-4-6, claude-sonnet-4-20250514, claude-haiku-4-5-20251001,
(及其他版本号变体)
```

### 3.3 添加模型组别名 (model_group_alias)

作为额外的兼容层，在 `general_settings` 中配置别名映射，确保未来可能出现的新模型名称变体也能正确路由：

```yaml
general_settings:
  model_group_alias:
    "claude-opus-4-6": "bedrock-claude-opus"
    "claude-sonnet-4-6": "bedrock-claude-sonnet"
    "claude-haiku-4-5": "bedrock-claude-haiku"
    # ... 更多变体
```

---

## 4. 修复验证

部署更新后，所有模型名称均返回 HTTP 200：

| 模型名称 | 修复前 | 修复后 |
|----------|--------|--------|
| `bedrock-claude-opus` | 200 | 200 |
| `bedrock-claude-sonnet` | 200 | 200 |
| `bedrock-claude-haiku` | 200 | 200 |
| `claude-sonnet-4-20250514` | 401 | **200** |
| `claude-haiku-4-5-20251001` | 401 | **200** |
| `claude-opus-4-6` | 401 | **200** |

---

## 5. 客户侧影响与建议

### 对终端用户的影响

- **主模型调用** (如 `bedrock-claude-opus`): 未受影响，始终正常
- **Claude Code 子代理功能**: 修复前约 80% 请求失败，导致 WebFetch、代码搜索、Explore 等辅助功能不可用；修复后已恢复正常
- **数据安全**: 无数据泄露风险，所有失败请求均在认证阶段被拒绝

### 客户配置建议

使用 Claude Code 连接 LiteLLM Gateway 时，推荐配置：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://<your-cloudfront-domain>",
    "ANTHROPIC_API_KEY": "<your-litellm-virtual-key>",
    "ANTHROPIC_MODEL": "bedrock-claude-opus",
    "CLAUDE_CODE_USE_BEDROCK": "0"
  }
}
```

> `CLAUDE_CODE_USE_BEDROCK` 设为 `"0"` 是因为实际的 Bedrock 调用由 LiteLLM Gateway 的 IAM Role 处理，客户端无需直接配置 Bedrock 凭证。

---

## 6. 架构优化方案

在修复 4xx 错误的过程中，我们对整体架构进行了全面审计，发现以下问题及对应的优化方案。这些改进将显著提高系统在生产环境中的稳定性，特别是减少 timeout 类故障。

### 6.1 [P0] CloudFront Origin 超时时间不足

**现状**: CloudFront `OriginReadTimeout` 配置为 60 秒（默认值）。

**问题**: LLM API 调用（尤其是 Claude Opus 等大模型的 streaming 响应）经常超过 60 秒。CloudFront 会在 60 秒后主动断开与 ALB 的连接，返回 **504 Gateway Timeout** 给客户端。这是生产环境中客户报告 timeout 的**最直接原因**。

> 注: LiteLLM 自身配置的 `request_timeout: 600`（10分钟），但 CloudFront 最大仅支持 180 秒。

**解决方案**: 修改 CloudFront Distribution 配置：

```yaml
# CloudFormation: 05-cloudfront.yaml
Origins:
  - Id: ALBOrigin
    CustomOriginConfig:
      OriginReadTimeout: 180        # 60 → 180 (CloudFront 最大值)
      OriginKeepaliveTimeout: 60    # 30 → 60 (减少连接重建开销)
```

### 6.2 [P0] ALB 空闲超时不足

**现状**: ALB 未显式配置 `IdleTimeout`，使用默认值 60 秒。

**问题**: 对于 streaming 响应，如果两次数据传输间隔超过 60 秒（Claude Opus 在复杂推理时思考时间较长），ALB 会主动断开连接。

**解决方案**: 修改 ALB 属性：

```yaml
# CloudFormation: 04-ecs.yaml
ALB:
  Type: AWS::ElasticLoadBalancingV2::LoadBalancer
  Properties:
    LoadBalancerAttributes:
      - Key: idle_timeout.timeout_seconds
        Value: "300"                # 默认60 → 300
```

### 6.3 [P1] 单 NAT Gateway — 单点故障与跨 AZ 延迟

**现状**: 整个 VPC 只有 1 个 NAT Gateway，部署在 AZ-a 的公有子网中。两个私有子网（AZ-a 和 AZ-b）共用同一个路由表，所有出站流量都经过这一个 NAT。

**问题**:

| 风险 | 影响 |
|------|------|
| **单点故障** | NAT Gateway 所在 AZ 故障时，两个 AZ 的 ECS 任务全部无法出站访问外部 API (OpenAI, Gemini 等) |
| **跨 AZ 延迟** | AZ-b 的 ECS 任务出站必须跨 AZ 到 AZ-a 的 NAT，增加 1-2ms 延迟 |
| **跨 AZ 费用** | 跨 AZ 数据传输额外产生 $0.01/GB 的费用 |
| **带宽瓶颈** | 单个 NAT Gateway 的并发连接数上限为 55,000/分钟，高并发 LLM 请求可能触发 `ErrorPortAllocation` |

**解决方案**: 每个 AZ 部署独立的 NAT Gateway 和路由表：

```
修复前:
  PrivateSubnet1 (AZ-a) ─┐
                          ├──→ NAT Gateway (AZ-a) → Internet
  PrivateSubnet2 (AZ-b) ─┘

修复后:
  PrivateSubnet1 (AZ-a) ──→ NAT Gateway-1 (AZ-a) → Internet
  PrivateSubnet2 (AZ-b) ──→ NAT Gateway-2 (AZ-b) → Internet
```

> 注: 增加 1 个 NAT Gateway 的成本约 $32/月 (固定费) + 流量费。

### 6.4 [P1] 添加 VPC Endpoint — 消除 NAT 瓶颈

**现状**: ECS 任务调用 Bedrock、S3、DynamoDB、Secrets Manager、CloudWatch Logs 全部通过 NAT Gateway 出公网再回 AWS。

**问题**: 不仅浪费 NAT 带宽和费用（$0.045/GB），还增加了不必要的网络跳转和延迟。Bedrock 作为最大的出站流量源，应优先走内网。

**解决方案**: 添加以下 VPC Endpoint：

| 服务 | Endpoint 类型 | 费用 | 优先级 | 收益 |
|------|--------------|------|--------|------|
| **Bedrock Runtime** | Interface | $0.01/GB + $0.01/h/AZ | P1 | 模型调用延迟降低 5-15ms，消除 NAT 单点对 Bedrock 的影响 |
| **S3** | Gateway | **免费** | P1 | ECS 启动时拉取配置文件走内网 |
| **DynamoDB** | Gateway | **免费** | P1 | Audit Log 写入走内网 |
| **Secrets Manager** | Interface | $0.01/h/AZ | P2 | ECS 启动时拉取密钥走内网 |
| **CloudWatch Logs** | Interface | $0.01/h/AZ | P2 | 日志推送走内网 |
| **ECR** | Interface | $0.01/h/AZ | P2 | 容器镜像拉取走内网 |

添加 Bedrock VPC Endpoint 后的流量路径变化：

```
修复前:
  ECS Task (Private Subnet AZ-b)
    → 跨AZ → NAT Gateway (AZ-a)
      → Internet Gateway
        → AWS Bedrock 公网端点
  延迟: ~15-25ms | 费用: $0.045/GB

修复后:
  ECS Task (Private Subnet)
    → 同 AZ 的 ENI (VPC Endpoint)
      → AWS 内网直达 Bedrock
  延迟: ~5-10ms | 费用: $0.01/GB
```

> S3 和 DynamoDB 的 Gateway Endpoint 完全免费，且无流量费，建议立即添加。

### 6.5 [P2] CloudWatch 告警自动通知

**现状**: 无自动告警机制，依赖人工监控发现问题。

**解决方案**: 添加 CloudWatch Alarm + SNS 通知：

| 告警规则 | 阈值 | 通知方式 |
|----------|------|----------|
| CloudFront 5xx 错误率 | > 1% 持续 5 分钟 | SNS → Email/Slack |
| CloudFront 4xx 错误率 | > 10% 持续 5 分钟 | SNS → Email/Slack |
| ECS RunningTaskCount | < DesiredCount 持续 3 分钟 | SNS → Email/Slack |
| Origin Latency p99 | > 30s 持续 5 分钟 | SNS → Email/Slack |

### 6.6 优化方案总览

```
                      ┌──────────────────────────────────┐
                      │          CloudFront CDN           │
                      │  OriginReadTimeout: 60s → 180s   │
                      └──────────────┬───────────────────┘
                                     │
                      ┌──────────────▼───────────────────┐
                      │     ALB (internet-facing)         │
                      │  IdleTimeout: 60s → 300s          │
                      └──────┬───────────────┬───────────┘
                             │               │
                   ┌─────────▼──┐      ┌─────▼────────┐
                   │ Public-1   │      │ Public-2     │
                   │ AZ-a       │      │ AZ-b         │
                   │ NAT-GW-1   │      │ NAT-GW-2 ⭐  │  ← 新增
                   └─────┬──────┘      └──────┬───────┘
                         │                    │
                   ┌─────▼──────┐      ┌──────▼───────┐
                   │ Private-1  │      │ Private-2    │
                   │ AZ-a       │      │ AZ-b         │
                   │ ECS Task   │      │ ECS Task     │
                   └──┬──┬──┬───┘      └──┬──┬──┬─────┘
                      │  │  │             │  │  │
           ┌──────────┘  │  └──────┐      │  │  │
           ▼             ▼         ▼      │  │  │
     ┌──────────┐  ┌──────────┐ ┌─────┐   │  │  │
     │ Bedrock  │  │   S3     │ │ DDB │   │  │  │
     │ VPC EP ⭐ │  │ GW EP ⭐ │ │GW EP│⭐  │  │  │
     │(Interface)│  │ (Free)  │ │(Free│   │  │  │
     └──────────┘  └──────────┘ └─────┘   │  │  │
                                          │  │  │
           OpenAI / Gemini ◄──────────────┘  │  │
           (仍走 NAT Gateway)                │  │
           RDS PostgreSQL ◄──────────────────┘  │
           ElastiCache Redis ◄──────────────────┘
           (VPC 内网直连，不走 NAT)

⭐ = 本次新增/优化项
```

### 6.7 预期收益

| 指标 | 当前 | 优化后 |
|------|------|--------|
| Bedrock 首 Token 延迟 (TTFT) | ~20ms 网络开销 | ~5ms (VPC Endpoint) |
| 最大 streaming 超时容忍 | 60s (CloudFront 截断) | 180s |
| NAT 单点故障影响 | 全部 AZ 不可用 | 仅影响单个 AZ |
| NAT 流量费 (Bedrock) | $0.045/GB | $0.01/GB (VPC EP) |
| NAT 流量费 (S3/DDB) | $0.045/GB | $0 (Gateway EP 免费) |
| 故障发现时间 | 人工巡检 | 秒级自动告警 |

---

## 7. 时间线

| 时间 (UTC) | 事件 |
|------------|------|
| 2026-04-14 14:50 | 监控发现 4xx 错误率 78%~92% |
| 2026-04-14 14:55 | 定位根因: Team 模型权限 + 路由配置双重问题 |
| 2026-04-14 15:13 | 更新 Team 模型权限列表 |
| 2026-04-14 15:23 | 修正模型路由配置，移除失效的 Anthropic 直连路由 |
| 2026-04-14 15:35 | ECS 滚动部署完成，全部模型验证通过 (HTTP 200) |
| 2026-04-14 15:36 | 确认修复完成 |

**总恢复时间**: 约 45 分钟
