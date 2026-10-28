-- ECS v4.13 修复：用户删除不彻底 + 旧发票存储路径被权限拦截
-- 适用：NAS 自托管版已部署数据库（PostgreSQL 15）
-- 执行：PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f migration-v4.13-delete-storage-fix.sql

BEGIN;

-- 1) 真正的删除用户：连同 GoTrue 登录账号一起删除，避免"删了再建"还沿用旧密码
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_id UUID)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NOT public.is_admin_or_service() THEN
    RAISE EXCEPTION '无用户管理权限';
  END IF;
  IF p_id = auth.uid() THEN
    RAISE EXCEPTION '不能删除当前登录账号';
  END IF;
  DELETE FROM public.user_companies WHERE user_id = p_id;
  DELETE FROM public.profiles WHERE id = p_id;
  DELETE FROM auth.identities WHERE user_id = p_id;
  DELETE FROM auth.users WHERE id = p_id;
END;
$fn$;

-- 2) Storage 读取：保留公司前缀规则，同时放行"发票表里属于本公司"的旧路径
DROP POLICY IF EXISTS "storage_objects_select" ON storage.objects;
CREATE POLICY "storage_objects_select" ON storage.objects
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
    OR (
      bucket_id = 'invoices'
      AND (
        (storage.foldername(name))[1] IN (
          SELECT company_id::text FROM public.user_companies WHERE user_id = auth.uid()
        )
        OR EXISTS (
          SELECT 1
          FROM public.invoices i
          JOIN public.user_companies uc
            ON uc.company_id = i.company_id AND uc.user_id = auth.uid()
          WHERE i.storage_path = storage.objects.name
             OR i.storage_path = 'invoices/' || storage.objects.name
        )
      )
    )
  );

COMMIT;
