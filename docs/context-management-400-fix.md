# LiteLLM Gateway 升级通知：修复 `context_management` 400 错误

> **现象一句话总结**：Claude Code 客户端访问 `https://aigw.enginez.link` 时返回 `400 context_management: Extra inputs are not permitted`，所有 Anthropic 模型（Sonnet 4.6 / Opus 4.7 等）均无法使用。

---

## 1. 错误现象

客户端报错（来自 Claude Code）：

```
API Error: 400 {"message":"context_management: Extra inputs are not permitted"}.
Received Model Group=claude-sonnet-4-6
Available Model Group Fallbacks=None
```

网关返回的原始 JSON：

```json
{
  "error": {
    "message": "{\"message\":\"context_management: Extra inputs are not permitted\"}. Received Model Group=claude-sonnet-4-6\nAvailable Model Group Fallbacks=None",
    "type": "None",
    "param": "None",
    "code": "400"
  }
}
```

---

## 2. 根因分析

Claude Code（CLI 客户端）在请求体中携带了 Anthropic 官方新参数 **`context_management`**（用于自动上下文管理 / 工具调用清理），目前网关后端的 LiteLLM proxy 版本不识别该字段，被 Pydantic 入参校验直接拦截，请求未透传到上游 Bedrock。

参数说明（Anthropic 官方）：

- 字段名：`context_management`
- 关联 beta：`anthropic-beta: context-management-2025-09-19`
- 典型 payload：
  ```json
  {
    "context_management": {
      "edits": [{"type": "clear_tool_uses_20250919"}]
    }
  }
  ```
- 对应 LiteLLM 支持 PR：<https://github.com/BerriAI/litellm/pull/16096>（2025-10 合并，建议 v1.77.0+ 版本已包含）

---

## 3. 复现步骤

### 3.1 基线请求（不带 `context_management`）—— 正常

```bash
curl -sS -X POST https://aigw.enginez.link/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-6",
    "max_tokens": 64,
    "messages": [{"role":"user","content":"ping"}]
  }'
```

返回 200，正常输出 `Pong!`。

### 3.2 带 `context_management` 字段 —— 报错

```bash
curl -sS -X POST https://aigw.enginez.link/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-6",
    "max_tokens": 64,
    "messages": [{"role":"user","content":"ping"}],
    "context_management": {"edits":[{"type":"clear_tool_uses_20250919"}]}
  }'
```

返回 400 `Extra inputs are not permitted`。

### 3.3 验证矩阵

| # | 测试条件 | 结果 |
|---|---|---|
| 1 | 普通请求，无 `context_management` | 200 OK |
| 2 | 加 `context_management` | 400 Pydantic 校验失败 |
| 3 | 加 `context_management` + `anthropic-beta` 头 | 400（同样失败） |
| 4 | 切换 `claude-opus-4-7` 重测 | 400（同样失败） |

→ 与上游模型无关，问题在 LiteLLM proxy 自身的入参校验层。

---

## 4. 影响范围

- **受影响客户端**：Claude Code（任意版本，因为该字段由客户端 SDK 自动注入，无法通过 env 关闭）
- **受影响模型**：所有走 LiteLLM 网关的 Anthropic 系列模型（Sonnet 4.6 / Opus 4.7 / Haiku 4.5 等）
- **受影响功能**：所有交互（首次握手即被拦截，不只是长上下文场景）
- **业务影响**：使用 `aigw.enginez.link` 的全部 Claude Code 用户当前**无法发起任何对话**

---

## 5. 修复方案

### 方案 A（推荐）：升级 LiteLLM proxy

将网关使用的 `litellm` 升级到 **v1.77.0 或更高版本**。

```bash
# Docker 部署
docker pull ghcr.io/berriai/litellm:main-latest
# 或 pip 部署
pip install --upgrade 'litellm>=1.77.0'
```

升级后 LiteLLM 会原生识别 `context_management` 并正确透传给 Bedrock Anthropic，**无需修改任何客户端配置**，且保留自动上下文管理能力。

### 方案 B（临时缓解）：开启 `drop_params`

如果暂时无法升级，可在 LiteLLM `config.yaml` 中加入：

```yaml
litellm_settings:
  drop_params: True
```

效果：LiteLLM 会丢弃所有它不识别的字段后再转发。

**副作用**：
- 失去 Claude 自动上下文管理能力（长会话会更早地撞 token 上限）
- 仅作为升级前的临时止血手段，不建议长期使用

### 方案对比

| 方案 | 操作成本 | 副作用 | 是否推荐 |
|---|---|---|---|
| A. 升级 LiteLLM | 中（需重启服务） | 无 | ✅ 推荐 |
| B. `drop_params: True` | 低（改 config 即可） | 丢失自动上下文管理 | ⚠️ 临时 |

---

## 6. 验证清单

升级 / 修复完成后，请按下列步骤回归验证：

- [ ] 步骤 3.1 的基线请求仍返回 200
- [ ] 步骤 3.2 的 `context_management` 请求返回 200（不再报 400）
- [ ] Claude Code CLI 在 `settings.litellm.json` 配置下能正常发起对话
- [ ] 长会话场景下 `context_management.edits` 能被正常处理（仅方案 A）

回归用 curl（升级后应直接 200）：

```bash
curl -sS -X POST https://aigw.enginez.link/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-sonnet-4-6",
    "max_tokens": 64,
    "messages": [{"role":"user","content":"ping"}],
    "context_management": {"edits":[{"type":"clear_tool_uses_20250919"}]}
  }'
```

---

## 7. 参考链接

- LiteLLM 支持 `context_management` 的 PR：<https://github.com/BerriAI/litellm/pull/16096>
- LiteLLM 发布说明（建议查看 v1.77.0 起的 changelog）：<https://github.com/BerriAI/litellm/releases>
- Anthropic Context Management 官方文档：<https://docs.claude.com/en/docs/build-with-claude/context-management>

---

**报告人**：AWS SA Team
**日期**：2026-06-04
**测试环境**：Claude Code CLI on Linux aarch64，配置文件 `~/.claude/settings.litellm.json`
