-- 敏感管理面 API 调用：IAM / 密钥 / WAF / 安全组 / KMS 的写操作
-- 用于发现"有人偷偷改权限、放开防护、动密钥"——按主体和时间排查。
SELECT
    eventtime,
    eventsource,
    eventname,
    useridentity.arn   AS principal,
    sourceipaddress    AS src_ip,
    errorcode,
    requestparameters
FROM {{DB}}.cloudtrail_logs
WHERE readonly = 'false'
  AND (
        eventsource = 'iam.amazonaws.com'
     OR eventsource = 'secretsmanager.amazonaws.com'
     OR eventsource = 'wafv2.amazonaws.com'
     OR eventsource = 'kms.amazonaws.com'
     OR (eventsource = 'ec2.amazonaws.com' AND eventname LIKE '%SecurityGroup%')
      )
  AND region = 'us-east-1'          -- 分区裁剪，大幅降低扫描量
  AND year IN ('2025', '2026')
ORDER BY eventtime DESC
LIMIT 500;
