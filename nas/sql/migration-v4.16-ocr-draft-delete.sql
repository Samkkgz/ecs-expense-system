-- ECS v4.16 修复：OCR 识别后保持草稿 + 成员可删除自己的草稿/驳回件 + 自动上传归属
-- 适用：NAS 自托管版已部署数据库（PostgreSQL 15）
-- 执行：PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f migration-v4.16-ocr-draft-delete.sql

BEGIN;

-- 1) OCR/服务角色不允许把发票改成 pending（提交审批只能由成员在前端确认后发起）
CREATE OR REPLACE FUNCTION public.prevent_member_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF auth.role() = 'service_role' THEN
    IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status = 'pending' THEN
      RAISE EXCEPTION '服务角色不能自动提交审批';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT public.is_admin_or_service() THEN
      IF NOT (OLD.status IN ('draft','rejected') AND NEW.status = 'pending') THEN
        RAISE EXCEPTION '普通用户只能提交待审批';
      END IF;
    ELSE
      IF NOT (OLD.status = 'pending' AND NEW.status IN ('approved','rejected')) THEN
        RAISE EXCEPTION '管理员只能审批待审批发票';
      END IF;
    END IF;
  ELSE
    IF NOT public.is_admin_or_service() THEN
      IF OLD.status NOT IN ('draft','rejected') THEN
        RAISE EXCEPTION '该发票当前不可修改';
      END IF;
    ELSE
      IF OLD.status = 'approved' THEN
        RAISE EXCEPTION '已审批发票已锁定';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

-- 2) 成员可删除自己的草稿/驳回发票（管理员/超管保持原策略）
DROP POLICY IF EXISTS "invoices_delete_member" ON public.invoices;
CREATE POLICY "invoices_delete_member" ON public.invoices
  FOR DELETE USING (
    uploaded_by = auth.uid()
    AND status IN ('draft','rejected')
  );

-- 3) 成员删除草稿/驳回发票时，可同步删除自己的发票文件
DROP POLICY IF EXISTS "storage_objects_delete_member" ON storage.objects;
CREATE POLICY "storage_objects_delete_member" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'invoices'
    AND EXISTS (
      SELECT 1
      FROM public.invoices i
      WHERE i.uploaded_by = auth.uid()
        AND i.status IN ('draft','rejected')
        AND (i.storage_path = storage.objects.name
             OR i.storage_path = 'invoices/' || storage.objects.name)
    )
  );

-- 4) insert_invoice 默认草稿：服务/自动上传未显式指定状态时也进入待提交
CREATE OR REPLACE FUNCTION public.insert_invoice(
  p_storage_path TEXT, p_original_filename TEXT, p_file_size INTEGER,
  p_invoice_date TEXT DEFAULT NULL, p_category_id BIGINT DEFAULT NULL,
  p_project_location TEXT DEFAULT NULL, p_uploaded_by UUID DEFAULT NULL,
  p_status TEXT DEFAULT 'draft', p_company_id BIGINT DEFAULT 1
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_date DATE;
  v_company_id BIGINT;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin','super_admin')) THEN
    p_status := 'draft';
    IF p_company_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.user_companies WHERE user_id = auth.uid() AND company_id = p_company_id) THEN
      RAISE EXCEPTION '无权向该公司提交发票';
    END IF;
  END IF;

  IF p_uploaded_by IS NULL AND auth.uid() IS NOT NULL THEN
    p_uploaded_by := auth.uid();
  END IF;
  v_company_id := COALESCE(p_company_id, 1);
  v_date := COALESCE(p_invoice_date::DATE, CURRENT_DATE);
  PERFORM 1 FROM public.invoices
  WHERE original_filename = insert_invoice.p_original_filename
    AND file_size = insert_invoice.p_file_size
    AND company_id = v_company_id;
  IF NOT FOUND THEN
    INSERT INTO public.invoices(
      storage_path, original_filename, file_size,
      category_id, project_location, uploaded_by, status, invoice_date, company_id
    ) VALUES (
      insert_invoice.p_storage_path, insert_invoice.p_original_filename, insert_invoice.p_file_size,
      p_category_id, p_project_location, p_uploaded_by, p_status, v_date, v_company_id
    );
  END IF;
  RETURN JSONB_BUILD_OBJECT('success', true);
END;
$fn$;

-- 5) 数据修正：成员名下的 pending 恢复为 draft（这些是被 OCR 误提交的）
ALTER TABLE public.invoices DISABLE TRIGGER trg_invoices_member_status;
UPDATE public.invoices i
SET status = 'draft'
WHERE i.status = 'pending'
  AND i.uploaded_by IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = i.uploaded_by AND p.role = 'member');
ALTER TABLE public.invoices ENABLE TRIGGER trg_invoices_member_status;

-- 6) 删除 RPC：管理员/服务角色不限；成员只能删自己的草稿/驳回件
CREATE OR REPLACE FUNCTION public.delete_invoice(p_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_storage_path TEXT;
BEGIN
  IF NOT public.is_admin_or_service() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.invoices
      WHERE id = p_id AND uploaded_by = auth.uid() AND status IN ('draft','rejected')
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
