-- master key 的“可疑”读取：排除 ECS 执行/任务角色后，剩下的都值得追查
-- 这些通常就是泄露源头候选：人为 IAM 用户/角色、异常 IP、CI 角色等。
SELECT
    eventtime,
    useridentity.arn        AS principal,
    useridentity.type       AS identity_type,
    sourceipaddress         AS src_ip,
    useragent,
    json_extract_scalar(requestparameters, '$.secretId') AS secret_id
FROM {{DB}}.cloudtrail_logs
WHERE eventsource = 'secretsmanager.amazonaws.com'
  AND eventname IN ('GetSecretValue', 'BatchGetSecretValue')
  AND requestparameters LIKE '%master-key%'
  AND COALESCE(useridentity.arn, '') NOT LIKE '%litellm-gw-ecs-execution-role%'
  AND COALESCE(useridentity.arn, '') NOT LIKE '%litellm-gw-ecs-task-role%'
  AND region = 'us-east-1'          -- 分区裁剪，大幅降低扫描量
  AND year IN ('2025', '2026')
ORDER BY eventtime DESC
LIMIT 500;
