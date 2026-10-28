-- ECS v4.16.2 修复：成员可删除自己的待提交/待审批/已驳回发票（含批量），已通过仍锁定
-- 适用：NAS 自托管版已部署数据库（PostgreSQL 15）
-- 执行：PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f migration-v4.16.2-member-delete-pending.sql

BEGIN;

-- 1) 发票删除：成员可删自己的 draft/rejected/pending
DROP POLICY IF EXISTS "invoices_delete_member" ON public.invoices;
CREATE POLICY "invoices_delete_member" ON public.invoices
  FOR DELETE USING (
    uploaded_by = auth.uid()
    AND status IN ('draft','rejected','pending')
  );

-- 2) 存储文件删除：与发票删除同步
DROP POLICY IF EXISTS "storage_objects_delete_member" ON storage.objects;
CREATE POLICY "storage_objects_delete_member" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'invoices'
    AND EXISTS (
      SELECT 1
      FROM public.invoices i
      WHERE i.uploaded_by = auth.uid()
        AND i.status IN ('draft','rejected','pending')
        AND (i.storage_path = storage.objects.name
             OR i.storage_path = 'invoices/' || storage.objects.name)
    )
  );

-- 3) 删除 RPC：成员可删自己的 draft/rejected/pending
CREATE OR REPLACE FUNCTION public.delete_invoice(p_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_storage_path TEXT;
BEGIN
  IF NOT public.is_admin_or_service() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.invoices
      WHERE id = p_id AND uploaded_by = auth.uid() AND status IN ('draft','rejected','pending')
    ) THEN
      RAISE EXCEPTION '无删除权限';
    END IF;
  END IF;
  SELECT storage_path INTO v_storage_path FROM public.invoices WHERE id = p_id;
  DELETE FROM public.invoices WHERE id = p_id;
  RETURN JSONB_BUILD_OBJECT('success', true, 'storage_path', v_storage_path);
END;
$fn$;

COMMIT;
