-- 控制台登录审计：root 登录、登录失败、无 MFA 登录
SELECT
    eventtime,
    useridentity.type      AS identity_type,
    useridentity.arn       AS principal,
    sourceipaddress        AS src_ip,
    json_extract_scalar(responseelements, '$.ConsoleLogin')                       AS login_result,
    json_extract_scalar(additionaleventdata, '$.MFAUsed')                          AS mfa_used,
    useragent
FROM {{DB}}.cloudtrail_logs
WHERE eventname = 'ConsoleLogin'
  AND (
        useridentity.type = 'Root'
     OR json_extract_scalar(responseelements, '$.ConsoleLogin') = 'Failure'
     OR json_extract_scalar(additionaleventdata, '$.MFAUsed') = 'No'
      )
  AND region = 'us-east-1'          -- 分区裁剪，大幅降低扫描量
  AND year IN ('2025', '2026')
ORDER BY eventtime DESC
LIMIT 500;
