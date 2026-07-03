-- 按网络接口(ENI)统计出站字节——定位"哪个容器/实例外传最多"
-- 结合 ECS 任务的 ENI 可归因到具体容器；异常放量的 ENI 值得深查。
SELECT
    interface_id,
    instance_id,
    COUNT(DISTINCT dstaddr)           AS distinct_dests,
    SUM(bytes)                        AS total_bytes,
    ROUND(SUM(bytes)/1024.0/1024, 2)  AS total_mb
FROM {{DB}}.vpc_flow_logs
WHERE action = 'ACCEPT'
  AND flow_direction = 'egress'
  AND dstaddr NOT LIKE '10.%'
  AND region = 'us-east-1'
  AND year IN ('2025', '2026')
GROUP BY interface_id, instance_id
ORDER BY total_bytes DESC
LIMIT 100;
