-- ECS v4.20.0 超级管理员修改用户密码
-- 适用：NAS 自托管版已部署数据库（PostgreSQL 15）
-- 执行：PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U supabase_admin -d postgres -f migration-v4.20.0-admin-reset-user-password.sql

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_reset_user_password(
  p_user_id UUID,
  p_new_password TEXT
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $fn$
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT EXISTS (
       SELECT 1 FROM public.profiles
       WHERE id = auth.uid() AND role = 'super_admin'
     ) THEN
    RAISE EXCEPTION '仅超级管理员可修改用户密码';
  END IF;

  IF p_new_password IS NULL OR length(p_new_password) < 6 THEN
    RAISE EXCEPTION '新密码至少6位';
  END IF;
  IF octet_length(p_new_password) > 72 THEN
    RAISE EXCEPTION '新密码不能超过72字节';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_user_id) THEN
    RAISE EXCEPTION '用户不存在';
  END IF;

  UPDATE auth.users
  SET encrypted_password = extensions.crypt(
        p_new_password,
        extensions.gen_salt('bf', 10)
      ),
      updated_at = now()
  WHERE id = p_user_id;
END;
$fn$;

COMMIT;
