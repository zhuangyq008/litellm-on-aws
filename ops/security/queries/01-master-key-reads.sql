-- 谁读取了 master key 密钥（GetSecretValue）——泄露溯源核心查询
-- 输出：时间 / 调用主体 ARN / 身份类型 / 源 IP / UserAgent / 目标密钥 / 错误码
-- 注：ECS 执行角色在每次部署拉密钥时也会出现，属正常；重点看非该角色的主体。
SELECT
    eventtime,
    useridentity.arn                                  AS principal,
    useridentity.type                                 AS identity_type,
    useridentity.sessioncontext.sessionissuer.username AS assumed_role,
    sourceipaddress                                   AS src_ip,
    useragent,
    json_extract_scalar(requestparameters, '$.secretId') AS secret_id,
    errorcode
FROM {{DB}}.cloudtrail_logs
WHERE eventsource = 'secretsmanager.amazonaws.com'
  AND eventname IN ('GetSecretValue', 'BatchGetSecretValue')
  AND requestparameters LIKE '%master-key%'
  AND region = 'us-east-1'          -- 分区裁剪，大幅降低扫描量
  AND year IN ('2025', '2026')          -- 按需收窄到 month/day 提速
ORDER BY eventtime DESC
LIMIT 500;
