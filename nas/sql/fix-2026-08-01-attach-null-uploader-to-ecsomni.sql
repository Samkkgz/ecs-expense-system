-- 一次性数据修正（2026-08-01）
-- 将逸创网络(company_id=1)历史无上传人的已通过发票归属到超级管理员 sam.lu@ecsomni.com
-- 执行环境：NAS psql，需以 service_role 身份通过 prevent_member_status_change 触发器校验

SET request.jwt.claim.role = 'service_role';

UPDATE public.invoices
SET uploaded_by = (SELECT id FROM public.profiles WHERE email = 'sam.lu@ecsomni.com'),
    updated_at = NOW()
WHERE uploaded_by IS NULL
  AND company_id = 1;

UPDATE public.profiles
SET name = 'Sam.Lu'
WHERE email = 'sam.lu@ecsomni.com';
