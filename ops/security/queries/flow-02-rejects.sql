-- 被拒绝(REJECT)的流量 Top 源/目的——端口扫描、暴力探测、异常连接
SELECT
    srcaddr        AS src_ip,
    dstaddr        AS dst_ip,
    dstport        AS dst_port,
    COUNT(*)       AS reject_count
FROM {{DB}}.vpc_flow_logs
WHERE action = 'REJECT'
  AND region = 'us-east-1'
  AND year IN ('2025', '2026')
GROUP BY srcaddr, dstaddr, dstport
ORDER BY reject_count DESC
LIMIT 100;
