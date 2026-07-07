# LiteLLM Gateway — Ops 模块（监控告警 + WAF）

一个**独立可部署 / 可卸载**的运维加固模块，针对客户三个关注点：

| 关注点 | 落地手段 |
|---|---|
| **异常流量** | ALB `RequestCount` 异常检测告警 + WAF **按 API-key 聚合限速**（单 IP 兜底）+ 4XX 激增告警 |
| **异常 token 消耗** | LiteLLM 原生 budget 强制限额（预防）+ budget/spend 告警（检测）— 见文末「可选」章节 |
| **限制 master key 访问模型** | 分层方案：业务方用 virtual key，master key 仅管理用；WAF 对管理路径做 IP 白名单；**master key 使用绊线告警**（key 一被调用即飞书告警，见 03-security 章节）|

> 本模块与网关本体**完全解耦**：只读引用主栈导出（`litellm-gw-ALBArn` / `-ECSClusterName` / `-ECSServiceName`），不修改任何主栈资源。独立部署脚本、独立文档、独立 CFN 栈，可随时整体删除而不影响网关。

---

## 架构

```
                        ┌─ CloudWatch 告警(ALB/ECS 原生指标) ─┐
                        │                                     ▼
业务流量 → GA → ALB ──►  WAF(Regional WebACL)            SNS Topic
                        │  · 管理路径 IP 白名单              │
                        │  · rate-based 限速                ▼
                        │  · AWS 托管规则 + 可选 Geo    alert-notifier Lambda
                        │  · BlockedRequests 告警 ──────────►│
                        └──────────────────────────────► 飞书/钉钉/企业微信群
```

四个独立栈（deploy-ops.sh 按序部署）：
- `litellm-gw-ops-monitoring` — SNS + 通知 Lambda + CloudWatch 告警 + Dashboard
- `litellm-gw-ops-waf` — Regional WebACL + IPSet + 规则 + 日志 + ALB 关联 + WAF 告警
- `litellm-gw-ops-security` — 安全事件告警（GuardDuty / 密钥读取 / root 登录 / **master key 使用**）
- `litellm-gw-ops-flowlogs` — VPC Flow Logs 取证落盘 + NAT 出站流量异常告警

---

## 前置条件

1. 主栈已部署，存在导出 `litellm-gw-ALBArn`、`litellm-gw-ECSClusterName`、`litellm-gw-ECSServiceName`
2. ECS 集群已开启 Container Insights（主栈 `04-ecs.yaml` 已启用）
3. 已准备好 IM 群机器人 webhook URL
4. 本地已配置 AWS CLI（账号 284367710968，us-east-1）

---

## 部署

```bash
cd litellm-gw
cp ops/params.example.env ops/params.env   # 填入 webhook / 白名单 / 阈值
bash ops/deploy-ops.sh
```

脚本会：自动创建工件桶 → 打包上传 `alert-notifier` Lambda → 部署 monitoring 栈 → 读取 SNS ARN → 部署 WAF 栈（把 WAF 告警接到同一 SNS）→ 部署 security 栈 → 探测 NAT 网关并部署 flowlogs 栈。

### 卸载

```bash
aws cloudformation delete-stack --stack-name litellm-gw-ops-flowlogs   --region us-east-1
aws cloudformation delete-stack --stack-name litellm-gw-ops-security   --region us-east-1
aws cloudformation delete-stack --stack-name litellm-gw-ops-waf        --region us-east-1
aws cloudformation delete-stack --stack-name litellm-gw-ops-monitoring --region us-east-1
```

WAF 的 `WebACLAssociation` 会随栈删除自动从 ALB 解绑，网关不受影响。

---

## 告警清单与默认阈值

| 告警 | 指标 | 默认条件 | 参数 | 栈 |
|---|---|---|---|---|
| **master key 使用** | `litellm-gw/audit MasterKeyRequests` | 5min 内 > 0（绊线：一被使用即告警）| `MasterKeyUsageThreshold` | security |
| 请求量异常 | ALB `RequestCount` | 异常检测带宽(3σ) 连续 2 周期越界 | `RequestCountAnomalyStdev` | monitoring |
| 4XX 激增 | ALB `HTTPCode_Target_4XX_Count` | 5min > 1000 连续 2 周期 | `Http4xxThreshold` | monitoring |
| 后端 5XX | ALB `HTTPCode_Target_5XX_Count` | 5min > 25 | `Http5xxThreshold` | monitoring |
| 延迟 p95 | ALB `TargetResponseTime` | p95 > 45s 连续 3 周期 | `TargetResponseTimeThreshold` | monitoring |
| CPU 高 | ECS `CPUUtilization` | > 85% 连续 3 周期 | `EcsCpuThreshold` | monitoring |
| 内存高 | ECS `MemoryUtilization` | > 85% 连续 3 周期 | `EcsMemThreshold` | monitoring |
| 任务数不足 | `RunningTaskCount` | < 期望值 连续 3 周期 | `DesiredTaskCount` | monitoring |
| 不健康目标 | ALB `UnHealthyHostCount` | > 0（需填 `TARGET_GROUP_FULL_NAME`）| `TargetGroupFullName` | monitoring |
| WAF 拦截激增 | `AWS/WAFV2 BlockedRequests` | 5min > 200 | `WafBlockedThreshold` | waf |
| NAT 出站异常 | `AWS/NATGateway BytesOutToDestination` | 异常检测带宽(6σ) 连续 2 周期越界 | `NatEgressAnomalyStdev` | flowlogs |

阈值均为 CFN 参数，上线后按实际流量在 `params.env` / `--parameter-overrides` 调整重新部署即可。

- **4XX 用 `Target_4XX` 而非 `ELB_4XX`**：后者是 ALB 自身的 400/460/463，抓不到 LiteLLM 返回的 401/403/429（凭证撞库信号）——这两个指标选错会导致撞库完全无感。
- **4XX=1000 / 5XX=25 / p95=45s / 3σ**：按 2000+ 员工规模校准（429 限额、400 上下文超长、LLM 长首字节在此规模下是常态噪声）；上线一周后按真实基线回调。
- **NAT 异常带宽默认 6σ**：用户爬坡期出站流量增长快、异常检测模型基线偏低，3σ 实测误报（正常增长 1.46 倍即触发）；6σ 仍能捕获量级级别的数据外泄。

---

## WAF 规则

优先级从高到低：

| 优先级 | 规则 | 动作 |
|---|---|---|
| 5 | Geo 白名单（可选，`ENABLE_GEO_BLOCK=true`）| 非 `ALLOWED_COUNTRIES` → Block |
| 10/11/12 | AWS 托管：Common / KnownBadInputs / IpReputation | 按厂商动作 |
| 20 | **管理路径锁定**（可选，`ENABLE_ADMIN_LOCKDOWN=true`）| 命中管理路径 **且** 源 IP ∉ 白名单 → Block |
| 30 | Rate-based 按 key（`Authorization` 头聚合）| 单 key 5min 超 `RATE_LIMIT_PER_KEY`(默认3000) → Block |
| 31 | Rate-based 按 key（`x-api-key` 头聚合，覆盖 Claude Code 原生头）| 同上 |
| 32 | Rate-based 按 IP（DoS 兜底）| 单 IP 5min 超 `RATE_LIMIT_PER_IP`(默认20000) → Block |
| 默认 | — | Allow |

> **为何按 key 而非按 IP 限速**：2000+ 员工共享公司出口 NAT IP，按 IP 限速会误杀整个公司；按 key 聚合才能精准限住"某一把 key 被刷"——正是 key 泄露滥用场景。`RATE_LIMIT_PER_IP` 须设为整个公司单出口 5 分钟峰值的若干倍。两条 key 规则关闭了 Sampled Requests（WAF 采样不受 RedactedFields 脱敏，否则 key 明文落采样）。

> **管理路径锁定为可开关**：`ENABLE_ADMIN_LOCKDOWN=false`（默认）时不创建 IPSet 与该规则，适合尚无固定运维出口 IP 的场景——此时 WAF 仅提供 rate-limit + 托管规则的「异常流量」防护。待有固定出口 IP 后，设 `ENABLE_ADMIN_LOCKDOWN=true` + 填 `ALLOWED_ADMIN_CIDRS`，重跑 `deploy-ops.sh` 即可启用 master key 管理路径限制。

**受管理路径锁定保护的前缀**（= 限制 master key 管理操作的作用面）：
`/key` `/user` `/team` `/organization` `/model/new` `/model/update` `/model/delete` `/config` `/ui` `/spend` `/global`

业务调用走 `/chat/completions`、`/v1/*`，不在锁定范围，virtual key 正常使用。

> **为何这样限制 master key**：LiteLLM 的 master key 等于超级管理员，能签发/删除 key、改配置、开管理 UI。把上述管理路径限制到白名单 IP，就等于「master key 只能从客户办公/运维 IP 使用」，且**无需把密钥值写进 WAF 规则**（避免密钥泄露面）。

### 维护管理白名单

改 `params.env` 里的 `ALLOWED_ADMIN_CIDRS` 后重跑 `deploy-ops.sh`；或直接更新 IPSet：

```bash
IPSET_ID=$(aws cloudformation describe-stacks --stack-name litellm-gw-ops-waf \
  --query "Stacks[0].Outputs[?OutputKey=='AdminAllowIpSetId'].OutputValue" --output text)
LOCK=$(aws wafv2 get-ip-set --scope REGIONAL --name litellm-gw-ops-admin-allowlist \
  --id "$IPSET_ID" --query LockToken --output text)
aws wafv2 update-ip-set --scope REGIONAL --name litellm-gw-ops-admin-allowlist \
  --id "$IPSET_ID" --lock-token "$LOCK" \
  --addresses 203.0.113.10/32 198.51.100.0/24
```

### 关于客户端 IP 与入口

当前活跃入口为 **Global Accelerator → ALB**。GA 已开启客户端 IP 保留，ALB（及关联的 WAF）看到的是**真实客户端 IP**，因此本模块的 IP 白名单、Geo 白名单、rate-based 限速全部**直接按真实源 IP 生效**，无需处理 `X-Forwarded-For`。

> 提示：ALB 上仍存在遗留的 `:80` listener（SG 仅放行 CloudFront 前缀列表）与 CloudFront 分发，但不在活跃路径。WAF 关联在 ALB 资源上会覆盖所有 listener；若确认 CloudFront 已弃用，建议后续在维护窗口下线 `:80` listener 与 CloudFront 分发，收敛攻击面。

> IPv4/IPv6：主栈 ALB 为 IPv4-only（未启用 dualstack），到达 ALB 的源地址均为 IPv4，管理白名单 IPSet 仅需 IPv4。若日后将 ALB 改为 dualstack，需再增加一个 IPv6 IPSet 并在管理路径锁定规则中用 `OrStatement` 同时引用，否则 IPv6 管理来源会被误拦。

---

## 飞书 / 钉钉 / 企业微信机器人配置

1. 在群里添加「自定义机器人」，拿到 webhook URL
2. 建议开启「加签」，把签名密钥填入 `WEBHOOK_SIGN_SECRET`（企业微信无加签，留空）
3. `IM_TYPE` 选 `feishu` / `dingtalk` / `wecom`

Lambda 用标准库实现三种平台的消息卡片与加签逻辑，webhook URL 与密钥存于 Secrets Manager（`litellm-gw-ops-im-webhook`），仅授予通知 Lambda 读取权限。

---

## 可选：异常 token 消耗的 LiteLLM 原生治理（不属于本模块，需改主 config）

本 Ops 模块**不做**自定义 token 指标（按既定方案）。token/预算维度的**预防与告警**推荐在网关本体启用 LiteLLM 原生能力：

在 `config/litellm-config.yaml` 增加：

```yaml
litellm_settings:
  max_budget: 500            # 全局月度美元硬上限
  budget_duration: 30d
  alerting: ["webhook"]      # 预算/花费/失败/挂起告警
  alerting_threshold: 300

general_settings:
  default_max_budget: 50     # 新建 key 默认限额
  default_budget_duration: 30d
```

LiteLLM 的 budget/spend 告警通知渠道由网关本体自行配置（如 Slack，或另行提供一个受鉴权保护的接收端点）。本 Ops 模块的通知 Lambda **仅接收 SNS**（CloudWatch 告警），不对外暴露公网入口，故不承接 LiteLLM webhook —— 这是刻意的最小暴露面设计。若后续需要把 LiteLLM 告警也汇入同一 IM 群，再单独评估「带鉴权的接收端点」方案。

### virtual key 签发 SOP（限制 master key 的关键运维动作）

master key 仅用于管理，业务方一律签发带预算/限速的 virtual key：

```bash
curl -X POST https://aigw.enginez.link/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "key_alias": "team-a",
        "models": ["bedrock-claude-sonnet","gpt-4o-mini"],
        "max_budget": 100,
        "budget_duration": "30d",
        "tpm_limit": 100000,
        "rpm_limit": 1000
      }'
```

> 该 `/key/generate` 调用本身受 WAF 管理路径锁定保护，只能从白名单 IP 发起。

---

## 安全事件告警（03-security 栈）

EventBridge 规则捕获安全事件，经 Input Transformer 塑形后直投通知 Lambda（复用飞书通道，不经 SNS、不改 Lambda 主链路）：

| 规则 | 触发 | 用途 |
|---|---|---|
| `guardduty-findings` | GuardDuty 发现 severity ≥ `GuardDutySeverityThreshold`(默认4) | 复用已启用的 GuardDuty 检测凭证异常/外泄 |
| `master-key-read` | Secrets Manager `GetSecretValue` 命中 `*master-key*` | **抓 master key 泄露源头**（ECS 部署拉密钥也会触发，看 principal 区分）|
| `root-console-login` | root 账户控制台登录 | 高危账户使用告警 |

### master key 使用告警（本栈的 CloudWatch Alarm，泄露滥用的靶心信号）

攻击者拿泄露的 master key 调 LLM API **不触碰任何 AWS 管理接口**，上表三条事件规则全部抓不到；这条告警直接盯"master key 被用于业务调用"本身：

- **数据链路**：审计流水(DynamoDB Stream) → 主仓 `lambda/stream-processor` 解析 key 身份 → `key_alias` 为空(=master key，与审计湖/QuickSight 口径一致)时以 **EMF** 打 CloudWatch 指标 `litellm-gw/audit MasterKeyRequests` → 告警 `litellm-gw-ops-master-key-usage`(Sum/5min > `MasterKeyUsageThreshold`，默认 0) → SNS → 飞书。端到端延迟约 1~6 分钟。
- **依赖主仓**：指标由主仓 stream-processor Lambda 产生（零 IAM 变更/零 API 调用，EMF 走日志通道）；该 Lambda 未部署新版时告警恒为 OK（无数据 = notBreaching）。
- **绊线用法**：日常流量应全部走 virtual key，master key 用量恒为零——一动即异常。若现阶段仍有合法 master key 流量，先调高阈值并推动收敛，收敛后回 0。
- **无 OKActions**：绊线语义下恢复通知无价值，且可被利用制造 ALARM/OK 乒乓淹没通道。稀疏指标下告警回 OK 需等数据点滑出评估回看范围（约 25 分钟），属 CloudWatch 既定行为。

> 前提：账号已开 CloudTrail(管理事件)与 GuardDuty。本栈依赖 monitoring 栈导出的 `NotifierFunctionArn`/`AlertTopicArn`，deploy-ops.sh 会按 monitoring→waf→security→flowlogs 顺序部署。

## CloudTrail 取证（ops/security/，master key 泄露溯源）

一次性建好 Athena 表，之后可随时查"谁在何时从哪个 IP 读了 master key / 改了 IAM / 登录了控制台"。**这是回答"上次 master key 怎么泄露的"的核心能力**——审计数据本就在 CloudTrail 里，缺的只是一张可查的表。

```bash
CLOUDTRAIL_BUCKET=<你的CloudTrail桶> \
ATHENA_OUTPUT=s3://<你有写权限的桶>/athena-results/ \
bash ops/security/setup-cloudtrail-athena.sh
```

脚本自动探测 org/账号级路径，建分区投影表 `litellm_gw_security.cloudtrail_logs`（无需 MSCK）。取证查询在 `ops/security/queries/`：

| 查询 | 回答 |
|---|---|
| `01-master-key-reads.sql` | 谁读过 master key 密钥（时间/主体/IP/UserAgent）|
| `02-master-key-reads-suspicious.sql` | 排除 ECS 角色后的可疑读取（泄露源候选）|
| `03-sensitive-admin-api.sql` | IAM/密钥/WAF/SG/KMS 的写操作 |
| `04-logins.sql` | root 登录 / 登录失败 / 无 MFA 登录 |
| `05-iam-key-lifecycle.sql` | access key 与 IAM 凭证变更（防提权）|

运行示例（`{{DB}}` 用 sed 替换；查询已带 `region='us-east-1'` 分区裁剪降本）：
```bash
aws athena start-query-execution --region us-east-1 \
  --query-string "$(sed 's/{{DB}}/litellm_gw_security/g' ops/security/queries/01-master-key-reads.sql)" \
  --result-configuration OutputLocation=s3://<桶>/athena-results/
```

> 成本提示：分区投影查询务必带 `region=` 且尽量收窄 `year/month/day`，否则会横扫多区域多日期（实测不裁剪一次扫 ~18GB）。

## VPC Flow Logs 取证（04-flowlogs 栈）

**为什么要自建 Flow Logs（即使 GuardDuty 已开）**：GuardDuty 的 `FLOW_LOGS` 特性会独立复制一份流日志做威胁检测，但**那份不落本账号、看不到原始记录**。自建 Flow Logs 提供原始连接记录供取证——回答"外传到哪个 IP、多少字节、什么时段、哪个 ENI"，是 GuardDuty 报警之外的取证广度。

`04-flowlogs.yaml` 部署：
- VPC Flow Logs（全流量，自定义字段含 `pkt-srcaddr/flow-direction/traffic-path`）→ 专用 S3 桶 `${ProjectName}-ops-flowlogs-<acct>`（加密+PAB+生命周期）
- **NAT 出站字节量异常检测告警**（`AWS/NATGateway BytesOutToDestination` 异常带宽，`NatEgressAnomalyStdev` 默认 6σ，见告警清单说明）→ 飞书：数据外泄的**实时**信号，复用 NAT 原生指标，零额外采集成本

建取证表（Flow Logs 到 S3 有 ~10 分钟延迟）：
```bash
bash ops/security/setup-flowlogs-athena.sh   # 建 litellm_gw_security.vpc_flow_logs（分区投影）
```
查询在 `ops/security/queries/flow-*.sql`：
| 查询 | 回答 |
|---|---|
| `flow-01-top-egress.sql` | 出站 TopN 外部目的地(按字节)——数据外泄排查 |
| `flow-02-rejects.sql` | REJECT Top 源/目的——扫描/暴力/异常连接 |
| `flow-03-egress-by-eni.sql` | 按 ENI 的出站字节——定位哪个容器外传最多 |

> GuardDuty 现状(本账号)：`FLOW_LOGS/DNS/CLOUDTRAIL/S3/RDS_LOGIN/RUNTIME_MONITORING` 均已启用；`litellm-gw-cluster` 的 ECS Runtime 覆盖为 HEALTHY。网络威胁检测已实时工作，自建 Flow Logs 补的是取证广度与 NAT 出站量告警。

## 部署前安全门禁

按团队规范，两个栈在部署前需过 `security-reviewer`：IAM 最小权限、WAF 规则正确性、无硬编码密钥、暴露面。已落实的加固：

- 通知 Lambda 仅接收 SNS，不暴露公网 Function URL（最小暴露面）
- IM webhook URL/密钥经 `put-secret-value` 写入 Secrets Manager（CloudTrail 对密钥体脱敏），不经 CFN 参数、不入模板
- WAF 日志脱敏 `authorization` / `x-api-key`，避免 API key 落日志
- 管理路径锁定覆盖 `/spend` `/global` 等敏感计费端点
- S3 工件桶启用 SSE + public-access-block；SNS 启用 KMS 加密

> 本地安全提示：`params.env` 含 webhook 明文，已被 `.gitignore` 忽略；调用脚本时可在命令前加空格（配合 `HISTCONTROL=ignorespace`）避免进入 shell history。

---

## 故障排查

### 症状：客户端（尤其 Claude Code）请求被 403 拦截 / 提示重新登录

**根因**：AWS 托管规则组 `AWSManagedRulesCommonRuleSet` 的多条 body 子规则会误伤 LLM / 代码 agent 的请求，在到达 LiteLLM **之前**被 WAF 拦成 403。Claude Code 收不到有效响应，会误判为未认证并提示 `/login`。已知会误报的三条（均已在 `02-waf.yaml` override 为 Count）：

| 子规则 | 误报原因 |
|---|---|
| `SizeRestrictions_BODY` | 请求体 > 8KB（system prompt + 工具定义 + 上下文普遍超限）|
| `GenericLFI_BODY` | 请求体含大量文件路径（`../`、`/etc/`、绝对路径）被误判为本地文件包含攻击 —— Claude Code 读写代码文件必带路径 |
| `CrossSiteScripting_BODY` | 请求体含 HTML/JS 代码片段被误判为 XSS |

> 排错要点：命中的**子规则**在日志的 `ruleGroupList[].terminatingRule.ruleId` 字段，`terminatingRuleId` 只显示到组名（`AWSCommon`）。修完一条可能撞下一条，需逐条看子规则名。

**判定方法**：
```bash
# 1) 用错误 key 打请求：返回 403(而非 401) → 请求没到 LiteLLM，被 WAF 前置拦截
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer sk-WRONG" \
  https://aigw.enginez.link/v1/messages -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"读 ../etc/passwd"}]}'

# 2) 用 Logs Insights 取一条完整 BLOCK 日志，看组内命中的子规则名
aws logs start-query --log-group-name aws-waf-logs-litellm-gw-ops \
  --start-time $(($(date +%s)-3600)) --end-time $(date +%s) \
  --query-string 'fields @message | filter action="BLOCK" | limit 3'
# 取 queryId 后 get-query-results，看 JSON 里：
#   ruleGroupList[].terminatingRule.ruleId  ← 真正命中的子规则（如 GenericLFI_BODY）
#   terminatingRuleMatchDetails[].location  ← 命中位置（如 BODY）
#   httpRequest.headers[User-Agent]         ← 确认是 claude-cli/x.x.x
```

**修复（已内置于 `02-waf.yaml`）**：在 `AWSCommon` 规则组用 `RuleActionOverrides` 把上表三条子规则改为 `Count`（仅计数不拦截），保留组内其余攻击防护。改后重跑 `deploy-ops.sh` 即可。

> 排错通法：任何"某类请求被拦"的问题，都先查 WAF 日志 `ruleGroupList[].terminatingRule.ruleId` 定位**具体子规则**（`terminatingRuleId` 只到组名），再针对性 override 为 Count。修完一条可能撞下一条（本项目就是先 `SizeRestrictions_BODY` 后 `GenericLFI_BODY`），逐条排。`KnownBadInputs`、`IpReputation` 组理论上也可能对特定 payload 误报。
