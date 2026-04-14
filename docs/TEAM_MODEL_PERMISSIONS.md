# Team 模型权限配置指南

> 本文档说明如何为 LiteLLM Gateway 的 Team 配置完整的模型访问权限，
> 重点解决 Claude Code 子代理因模型名称不匹配导致 `401 team_model_access_denied` 的问题。

---

## 1. 问题背景

Claude Code 连接 LiteLLM Gateway 时，**主模型**使用用户在 `ANTHROPIC_MODEL` 中配置的名称（如 `bedrock-claude-opus`）。但 Claude Code 内部的**子代理**（Subagent）在执行 WebFetch、代码搜索、Explore 等辅助操作时，会自动使用 **Anthropic 原生模型名称**发起请求：

```
主模型请求:   model: "bedrock-claude-opus"         ← 用户配置的名称
子代理请求:   model: "claude-haiku-4-5-20251001"    ← Anthropic 原生名称（自动）
子代理请求:   model: "claude-sonnet-4-20250514"     ← Anthropic 原生名称（自动）
```

如果 Team 的 `models` 列表中只包含 Bedrock 别名（`bedrock-claude-*`），子代理的请求会被 LiteLLM 的权限检查拦截，返回：

```json
{
  "error": {
    "message": "team not allowed to access model",
    "type": "team_model_access_denied",
    "code": "401"
  }
}
```

---

## 2. 配置架构

LiteLLM 的模型路由涉及三层配置，Team 权限必须覆盖所有层：

```
┌─────────────────────────────────────────────────────┐
│ 客户端请求                                            │
│   model: "claude-haiku-4-5-20251001"                 │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────▼────────────────┐
          │ [1] Team 权限检查             │
          │ models 列表中是否包含该名称？   │  ← 本文档重点
          │ 不匹配 → 401 拒绝            │
          └────────────┬────────────────┘
                       │ 通过
          ┌────────────▼────────────────┐
          │ [2] model_group_alias 解析   │
          │ 别名映射到 model_list 中的     │
          │ model_name                   │
          └────────────┬────────────────┘
                       │
          ┌────────────▼────────────────┐
          │ [3] model_list 路由          │
          │ 匹配 model_name → 调用       │
          │ litellm_params.model         │
          └─────────────────────────────┘
```

**关键：Team 权限检查发生在 alias 解析之前。** 即使 `model_group_alias` 配置了映射，如果 Team `models` 列表中没有该名称，请求直接被拒绝。

---

## 3. 推荐的 Team 模型权限清单

### 3.1 Bedrock Claude 模型（默认配置）

以下是通过 AWS Bedrock 提供的 Claude 模型，分为两类名称：

| 分类 | model_name | 说明 | 必须包含 |
|------|-----------|------|---------|
| **Bedrock 别名** | `bedrock-claude-opus` | Opus 4.6 — 用户主模型 | 是 |
| | `bedrock-claude-sonnet` | Sonnet 4.6 | 是 |
| | `bedrock-claude-haiku` | Haiku 4.5 | 是 |
| **Anthropic 原生名** | `claude-opus-4-6` | Opus — 子代理使用 | 是 |
| | `claude-sonnet-4-20250514` | Sonnet — 子代理使用 | 是 |
| | `claude-haiku-4-5-20251001` | Haiku — 子代理使用 | 是 |
| **别名变体** | `claude-opus-4-6-20250514` | Opus 带日期后缀 | 建议 |
| | `claude-sonnet-4-6` | Sonnet 短名称 | 建议 |
| | `claude-sonnet-4-6-20250514` | Sonnet 带日期后缀 | 建议 |
| | `claude-haiku-4-5` | Haiku 短名称 | 建议 |

> **为什么需要"别名变体"？** Claude Code 不同版本可能使用不同格式的模型名。
> 这些变体通过 `model_group_alias` 映射到 Bedrock 路由，但 Team 权限检查在 alias 解析之前，
> 所以也需要加入 Team 的 `models` 列表。

### 3.2 其他模型（按需添加）

| model_name | Provider | 说明 |
|-----------|----------|------|
| `gpt-4o` | OpenAI | GPT-4o |
| `gpt-4o-mini` | OpenAI | GPT-4o Mini |
| `gpt-4.1` | OpenAI | GPT-4.1 |
| `gemini-2.0-flash` | Google | Gemini 2.0 Flash |
| `gemini-2.5-pro` | Google | Gemini 2.5 Pro |

---

## 4. 配置操作

### 4.1 创建新 Team

```bash
curl -X POST 'https://<your-domain>/team/new' \
  -H 'Authorization: Bearer <MASTER_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{
    "team_alias": "dev",
    "models": [
      "bedrock-claude-opus",
      "bedrock-claude-sonnet",
      "bedrock-claude-haiku",
      "claude-opus-4-6",
      "claude-opus-4-6-20250514",
      "claude-sonnet-4-20250514",
      "claude-sonnet-4-6",
      "claude-sonnet-4-6-20250514",
      "claude-haiku-4-5-20251001",
      "claude-haiku-4-5",
      "gpt-4o",
      "gpt-4o-mini",
      "gpt-4.1",
      "gemini-2.0-flash",
      "gemini-2.5-pro"
    ],
    "max_budget": 500.0,
    "budget_duration": "1mo"
  }'
```

### 4.2 更新现有 Team

```bash
curl -X POST 'https://<your-domain>/team/update' \
  -H 'Authorization: Bearer <MASTER_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{
    "team_id": "<TEAM_ID>",
    "models": [
      "bedrock-claude-opus",
      "bedrock-claude-sonnet",
      "bedrock-claude-haiku",
      "claude-opus-4-6",
      "claude-opus-4-6-20250514",
      "claude-sonnet-4-20250514",
      "claude-sonnet-4-6",
      "claude-sonnet-4-6-20250514",
      "claude-haiku-4-5-20251001",
      "claude-haiku-4-5",
      "gpt-4o",
      "gpt-4o-mini",
      "gpt-4.1",
      "gemini-2.0-flash",
      "gemini-2.5-pro"
    ]
  }'
```

### 4.3 验证权限

使用 Team 下的 Virtual Key 逐个测试模型访问：

```bash
# 测试 Bedrock 别名
curl -s -o /dev/null -w "%{http_code}" \
  -X POST 'https://<your-domain>/v1/chat/completions' \
  -H 'x-api-key: <VIRTUAL_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{"model": "bedrock-claude-haiku", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 5}'

# 测试 Anthropic 原生名（子代理使用的名称）
curl -s -o /dev/null -w "%{http_code}" \
  -X POST 'https://<your-domain>/v1/chat/completions' \
  -H 'x-api-key: <VIRTUAL_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{"model": "claude-haiku-4-5-20251001", "messages": [{"role": "user", "content": "hi"}], "max_tokens": 5}'
```

预期：所有模型均返回 `200`。如返回 `401`，检查 Team 的 `models` 列表是否遗漏。

---

## 5. 与 config.yaml 的对应关系

Team 的 `models` 列表必须覆盖 `litellm-config.yaml` 中的两个部分：

### 5.1 model_list 中的所有 model_name

```yaml
model_list:
  - model_name: bedrock-claude-opus       # ← Team 必须包含
  - model_name: bedrock-claude-sonnet     # ← Team 必须包含
  - model_name: bedrock-claude-haiku      # ← Team 必须包含
  - model_name: claude-opus-4-6           # ← Team 必须包含
  - model_name: claude-sonnet-4-20250514  # ← Team 必须包含
  - model_name: claude-haiku-4-5-20251001 # ← Team 必须包含
  - model_name: gpt-4o                    # ← Team 必须包含
  # ...
```

### 5.2 model_group_alias 中的所有 key

```yaml
general_settings:
  model_group_alias:
    "claude-opus-4-6": "bedrock-claude-opus"             # ← 左侧 key 也要加入 Team
    "claude-opus-4-6-20250514": "bedrock-claude-opus"     # ← 同上
    "claude-sonnet-4-6": "bedrock-claude-sonnet"          # ← 同上
    "claude-sonnet-4-6-20250514": "bedrock-claude-sonnet" # ← 同上
    "claude-haiku-4-5": "bedrock-claude-haiku"            # ← 同上
    # ...
```

**规则：`model_list` 的每个 `model_name` + `model_group_alias` 的每个 key = Team `models` 的完整清单。**

---

## 6. 常见问题

### Q: 可以用空数组 `[]` 允许所有模型吗？

可以。将 Team 的 `models` 设为 `[]` 表示不做模型级限制，Team 下的 Key 可以访问所有已配置的模型。适用于内部开发团队，但不建议用于对外提供服务的场景。

### Q: 新增模型后需要更新 Team 吗？

是的。每次在 `litellm-config.yaml` 中添加新的 `model_name` 或 `model_group_alias`，都需要同步更新 Team 的 `models` 列表，否则新模型无法被 Team 下的 Key 访问。

### Q: Claude Code 子代理具体使用哪些模型名？

Claude Code 子代理使用 Anthropic 官方模型名，具体名称取决于 Claude Code 版本。已知的名称包括：

- `claude-haiku-4-5-20251001` — 轻量级任务（WebFetch、代码搜索等）
- `claude-sonnet-4-20250514` — 中等复杂度任务
- `claude-opus-4-6` — 复杂推理任务

建议同时覆盖带日期后缀和不带日期后缀的变体，以兼容未来版本。

### Q: model_group_alias 能否替代在 Team 中添加这些名称？

**不能。** LiteLLM 的权限检查顺序是：先检查 Team 权限 → 再解析 alias。alias 仅影响路由，不影响权限判定。即使 alias 配置正确，Team 中缺少该名称仍会返回 401。
