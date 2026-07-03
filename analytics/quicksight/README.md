# LiteLLM Gateway — QuickSight 看板

基于**审计湖 + Flow Logs**(Athena)的业务/用量/安全分析看板。与实时运维分工:

- **CloudWatch 看板**(`litellm-gw-ops`):实时运维——延迟/5XX/CPU/健康(QuickSight 读不了 CloudWatch 指标)
- **QuickSight 看板**(本目录):用量、token、应用层安全、网络取证

## 快速开始

```bash
# 1) 建策展视图(幂等)——用 Athena workgroup litellm-gw-audit
#    (views.sql 里两条 CREATE OR REPLACE VIEW，可用 athena_run 或控制台执行)
# 2) 建数据源 + 两个 SPICE 数据集 + 授 QS 服务角色 S3 权限 + 触发摄取
bash analytics/quicksight/setup-quicksight.sh
# 3) 到 QuickSight 控制台，用 ds-usage / ds-egress 两个数据集拖拽建 Analysis
```

## 数据源与数据集

**数据源(1)**:Athena `litellm-gw-athena`(workgroup `litellm-gw-audit`)。

| 数据集(SPICE) | 底层视图 | 服务的 Sheet |
|---|---|---|
| `litellm-gw-ds-usage` | `litellm-gw_audit.vw_qs_usage` | 用量总览 / token / 安全与异常 |
| `litellm-gw-ds-egress` | `litellm_gw_security.vw_qs_egress` | 网络取证 |

> **QS 服务角色 S3 权限是前提**:QS 跑 Athena 需读源桶(审计桶、flowlogs桶)+写结果。setup 脚本已用最小权限内联策略 `litellm-gw-quicksight-s3` 授到 `aws-quicksight-service-role-v0`。缺失会报 `PERMISSION_DENIED: s3:ListBucket`。

## 建议 Sheet 与指标

**Sheet1 使用总览**(ds-usage)
- KPI:总请求、总 token(输入/输出)、活跃 session/device、工具调用率、平均 token/请求
- 请求量趋势(按 request_date)、模型分布(model)、call_type 分布

**Sheet2 Token**(ds-usage;成本按你要求暂不做)
- token 趋势(prompt/completion/cached/reasoning 堆叠)
- 按 model 的 token、**缓存命中率**(cache_hit_ratio)趋势
- Top 消耗者:按 **key_alias / team_id / session_id** 的 total_tokens

**Sheet3 安全与异常**(ds-usage)
- **master key 用量**:is_master_key=true 的请求/token 占比与趋势(⚠️ 见下方数据说明)
- **按 key 的 token 异常**:key_alias × 日期热力/趋势,突增=疑似盗用
- finish_reason 分布(`content_filter` 激增=滥用)、source_ip Top(注意空值)

**Sheet4 网络取证**(ds-egress)
- 出站字节趋势(is_external=true)、Top 目的地(dest_ip/dest_port)、REJECT(action) Top、按 interface_id 的出站量

## 字段与数据说明(重要)
- **PII**:视图已剔除 `raw_messages/raw_response/*preview`,看板不含明文对话
- **key_alias 为空 ⇒ is_master_key=true**,作 master key 用量的代理信号
- ⚠️ **历史数据**:key 身份列是 2026-07-03 补的;**此前的记录 key_alias 为空 → 会被计为 master key**。master key/按 key 归因类图表**只对补列之后的数据准确**,加日期筛选(request_date ≥ 2026-07-03)看真实情况
- **source_ip 部分为空**:同批修复了 metadata 解析(此前 ast 解析失败致 source_ip 常空),补列后新数据有值;历史仍可能空
- **成本**:本期不做(未引入模型单价表)。将来要做:建 `ref_model_pricing`(model→输入/输出单价)数据集,在 QS 里 join ds-usage 计算 est_cost

## SPICE 刷新
数据集为 SPICE(看板秒开、控 Athena 扫描成本)。建议设**每日定时刷新**:
```bash
aws quicksight create-refresh-schedule --aws-account-id <acct> --data-set-id litellm-gw-ds-usage ...
```
或在 QS 控制台 Dataset → Refresh 设置。
