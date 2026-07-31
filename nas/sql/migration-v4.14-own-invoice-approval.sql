-- ECS v4.14 权限模型：成员仅见本人发票 + 提交审批 + 审批后锁定
-- 适用：NAS 自托管版已部署数据库（PostgreSQL 15）
-- 执行：PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f migration-v4.14-own-invoice-approval.sql

BEGIN;

-- 1) 状态扩展：draft(待提交) -> pending(待审批) -> approved/rejected
ALTER TABLE public.invoices DROP CONSTRAINT IF EXISTS invoices_status_check;
ALTER TABLE public.invoices ADD CONSTRAINT invoices_status_check
  CHECK (status IN ('draft','pending','approved','rejected'));
ALTER TABLE public.invoices ALTER COLUMN status SET DEFAULT 'draft';

-- 2) 发票读取：成员只能看自己上传的；管理员/服务角色看全部
DROP POLICY IF EXISTS "invoices_select" ON public.invoices;
CREATE POLICY "invoices_select" ON public.invoices
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
    OR uploaded_by = auth.uid()
  );

-- 3) 发票新增：成员只能以自己身份往所属公司插入；管理员/服务角色不限
DROP POLICY IF EXISTS "invoices_insert" ON public.invoices;
CREATE POLICY "invoices_insert" ON public.invoices
  FOR INSERT WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
    OR (
      uploaded_by = auth.uid()
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
  );

-- 4) 发票更新：成员只能改自己的 draft/rejected，可提交为 pending；管理员/服务角色可改（审批锁由触发器控制）
DROP POLICY IF EXISTS "invoices_update_admin" ON public.invoices;
DROP POLICY IF EXISTS "invoices_update_member" ON public.invoices;
CREATE POLICY "invoices_update_admin" ON public.invoices
  FOR UPDATE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  )
  WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  );
CREATE POLICY "invoices_update_member" ON public.invoices
  FOR UPDATE USING (
    uploaded_by = auth.uid()
    AND status IN ('draft','rejected')
  )
  WITH CHECK (
    uploaded_by = auth.uid()
    AND status IN ('draft','rejected','pending')
  );

-- 5) 删除保持管理员/服务角色
DROP POLICY IF EXISTS "invoices_delete" ON public.invoices;
CREATE POLICY "invoices_delete" ON public.invoices
  FOR DELETE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  );

-- 6) 审批/锁定触发器：成员只能 draft/rejected->pending；管理员只能 pending->approved/rejected；approved 对所有用户锁定（服务角色除外）
CREATE OR REPLACE FUNCTION public.prevent_member_status_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF auth.role() = 'service_role' THEN
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

-- 7) 上传 RPC：成员新上传默认 draft（待提交），管理员/服务角色保持原默认 pending
CREATE OR REPLACE FUNCTION public.insert_invoice(
  p_storage_path TEXT, p_original_filename TEXT, p_file_size INTEGER,
  p_invoice_date TEXT DEFAULT NULL, p_category_id BIGINT DEFAULT NULL,
  p_project_location TEXT DEFAULT NULL, p_uploaded_by UUID DEFAULT NULL,
  p_status TEXT DEFAULT 'pending', p_company_id BIGINT DEFAULT 1
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

-- 8) Storage 读取：成员只能读自己发票关联的文件，不再按公司开放
DROP POLICY IF EXISTS "storage_objects_select" ON storage.objects;
CREATE POLICY "storage_objects_select" ON storage.objects
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
    OR (
      bucket_id = 'invoices'
      AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.uploaded_by = auth.uid()
          AND (i.storage_path = storage.objects.name
               OR i.storage_path = 'invoices/' || storage.objects.name)
      )
    )
  );

-- 9) 报表：仅管理员/服务角色可见（成员只能看自己的发票数据，不看公司级汇总）
DROP POLICY IF EXISTS "reports_select" ON public.expense_reports;
CREATE POLICY "reports_select" ON public.expense_reports
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  );

-- 10) auth 函数空值安全：storage 请求把 sub/role 设为空字符串时，避免 uuid 转换报 400
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $function$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', TRUE), '')::UUID,
    (regexp_match(current_setting('request.jwt.claims', TRUE), '"sub"[^:]*:\s*"([^"]+)"'))[1]::UUID
  );
$function$;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $function$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.role', TRUE), ''),
    (regexp_match(current_setting('request.jwt.claims', TRUE), '"role"[^:]*:\s*"([^"]+)"'))[1]
  );
$function$;

COMMIT;
