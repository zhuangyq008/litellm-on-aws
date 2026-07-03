-- QuickSight 策展视图（QS datasets 的底层；剔除 PII，含计算字段）
-- 幂等：CREATE OR REPLACE。用 Athena workgroup litellm-gw-audit 执行。

-- 1) 用量/成本(token)/应用层安全 —— 主数据集 ds_usage 的来源
CREATE OR REPLACE VIEW "litellm-gw_audit".vw_qs_usage AS
SELECT
  date_parse(start_time, '%Y-%m-%d %H:%i:%s.%f')                         AS request_ts,
  CAST(date_parse(start_time, '%Y-%m-%d %H:%i:%s.%f') AS date)           AS request_date,
  model, call_type, finish_reason,
  prompt_tokens, completion_tokens, total_tokens, cached_tokens, reasoning_tokens,
  CASE WHEN prompt_tokens > 0 THEN cached_tokens * 1.0 / prompt_tokens ELSE 0 END AS cache_hit_ratio,
  has_tool_calls, message_count,
  key_alias, key_hash, team_id, key_user_id,
  CASE WHEN key_alias = '' OR key_alias IS NULL THEN 'master_key' ELSE 'virtual_key' END AS key_type,
  session_id, device_id, source_ip,
  year, month, day
FROM "litellm-gw_audit".audit_logs;
-- 注意：raw_messages/raw_response/preview 等含明文对话的字段一律不进视图(PII)。
-- 注意：key_alias 是补 key 身份列(2026-07-03)之后才有值；此前的历史记录 is_master_key 会偏高。

-- 2) 网络出站(取证) —— 数据集 ds_egress 的来源，按天/目的地/动作预聚合以控成本
CREATE OR REPLACE VIEW litellm_gw_security.vw_qs_egress AS
SELECT
  year, month, day, region, action, flow_direction,
  dstaddr AS dest_ip, dstport AS dest_port, interface_id,
  NOT regexp_like(dstaddr, '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)') AS is_external,
  COUNT(*)                        AS flows,
  SUM(bytes)                      AS bytes,
  SUM(packets)                    AS packets
FROM litellm_gw_security.vpc_flow_logs
WHERE region = 'us-east-1'
GROUP BY year, month, day, region, action, flow_direction, dstaddr, dstport, interface_id;
