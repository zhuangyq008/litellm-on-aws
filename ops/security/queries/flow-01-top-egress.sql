-- 出站流量 TopN 外部目的地（按字节）——数据外泄排查核心
-- 只看放行的出站、且目的不在 VPC 内网(10.0.0.0/16)的流量。
SELECT
    dstaddr                          AS dest_ip,
    dstport                          AS dest_port,
    COUNT(*)                         AS flows,
    SUM(bytes)                       AS total_bytes,
    ROUND(SUM(bytes)/1024.0/1024, 2) AS total_mb
FROM {{DB}}.vpc_flow_logs
WHERE action = 'ACCEPT'
  AND flow_direction = 'egress'
  AND dstaddr NOT LIKE '10.%'
  AND region = 'us-east-1'
  AND year IN ('2025', '2026')       -- 按需收窄 month/day
GROUP BY dstaddr, dstport
ORDER BY total_bytes DESC
LIMIT 100;
