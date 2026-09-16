# Claude Code 对接 LiteLLM Gateway 配置指南

## 前提条件

- 已安装 Claude Code CLI
- 已获取 LiteLLM API Key（向管理员申请，格式为 `sk-xxxx`）

## 配置方式

### 方式一：环境变量（推荐）

在你的 shell 配置文件（`~/.bashrc` / `~/.zshrc`）中添加：

```bash
export ANTHROPIC_BASE_URL="https://aigw.enginez.link"
export ANTHROPIC_API_KEY="sk-你的LiteLLM-Key"
```

保存后执行：

```bash
source ~/.bashrc  # 或 source ~/.zshrc
```

### 方式二：Claude Code settings.json

编辑 Claude Code 配置文件：

- **macOS / Linux**: `~/.claude/settings.json`
- **Windows**: `%USERPROFILE%\.claude\settings.json`

添加以下内容：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://aigw.enginez.link",
    "ANTHROPIC_API_KEY": "sk-你的LiteLLM-Key"
  }
}
```

> 如果文件中已有其他配置，将 `env` 部分合并进去即可。

### 方式三：项目级配置

在项目根目录创建 `.claude/settings.json`，内容同方式二。这样配置仅对该项目生效，适合团队协作场景。

## 模型配置（可选）

如需指定使用的模型，在 `settings.json` 中添加：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://aigw.enginez.link",
    "ANTHROPIC_API_KEY": "sk-你的LiteLLM-Key",
    "ANTHROPIC_MODEL": "bedrock-claude-opus",
    "CLAUDE_CODE_USE_BEDROCK": "0"
  }
}
```

也可以在启动时通过参数指定模型：

```bash
claude --model bedrock-claude-opus
```

## 可用模型

| 模型名称 | 说明 |
|---------|------|
| `bedrock-claude-opus` | Claude Opus (AWS Bedrock) |
| `bedrock-claude-haiku` | Claude Haiku (AWS Bedrock) |

## 验证配置

启动 Claude Code 后，执行以下命令确认连接正常：

```bash
claude --model bedrock-claude-opus -p "say hi"
```

如果返回正常响应，说明配置成功。

## 常见问题

### Q: 报错 "Authentication Error"
检查 API Key 是否正确，必须以 `sk-` 开头。

### Q: 报错 "Connection refused" 或超时
确认网络可以访问 `https://aigw.enginez.link`，可用 curl 测试：
```bash
curl https://aigw.enginez.link/health/liveliness
# 应返回: "I'm alive!"
```

### Q: 模型名称报错 "model not found"
优先使用上方「可用模型」表格中的名称。Anthropic 原生模型名（如
`claude-sonnet-4-20250514`、`claude-haiku-4-5-20251001`）已通过
`model_group_alias` 映射到对应的 Bedrock 路由，Claude Code 的 subagent 会
直接发原生名，无需额外配置。若仍报此错，说明该原生名尚未加入映射表，联系
管理员在 `config/litellm-config.yaml` 补一条。

### Q: 如何查看所有可用模型？
```bash
curl -s https://aigw.enginez.link/v1/models \
  -H "x-api-key: sk-你的Key" | python3 -m json.tool
```
