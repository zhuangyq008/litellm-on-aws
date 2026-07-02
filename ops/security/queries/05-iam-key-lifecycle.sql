-- IAM 凭证生命周期：新建/删除 access key、创建用户、附加/内联策略
-- 泄露事件后排查"攻击者是否借机新建了长期凭证或提权"。
SELECT
    eventtime,
    eventname,
    useridentity.arn   AS actor,
    sourceipaddress    AS src_ip,
    json_extract_scalar(requestparameters, '$.userName') AS target_user,
    errorcode
FROM {{DB}}.cloudtrail_logs
WHERE eventsource = 'iam.amazonaws.com'
  AND eventname IN (
        'CreateAccessKey', 'DeleteAccessKey', 'UpdateAccessKey',
        'CreateUser', 'CreateLoginProfile', 'UpdateLoginProfile',
        'AttachUserPolicy', 'AttachRolePolicy', 'PutUserPolicy', 'PutRolePolicy',
        'CreateRole', 'UpdateAssumeRolePolicy'
      )
  AND region = 'us-east-1'          -- 分区裁剪，大幅降低扫描量
  AND year IN ('2025', '2026')
ORDER BY eventtime DESC
LIMIT 500;
