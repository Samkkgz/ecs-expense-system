-- ECS v4.15 审批中心：管理员仅本公司、超管全部公司、成员仅本人
-- 适用：NAS 自托管版已部署数据库（PostgreSQL 15）
-- 执行：PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U postgres -d postgres -f migration-v4.15-approval-center.sql

BEGIN;

-- 1) 发票读取：super_admin 全部；admin 仅本公司；成员仅本人
DROP POLICY IF EXISTS "invoices_select" ON public.invoices;
CREATE POLICY "invoices_select" ON public.invoices
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'admin')
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
    OR uploaded_by = auth.uid()
  );

-- 2) 发票新增：super_admin 全部；admin/成员仅自己公司
DROP POLICY IF EXISTS "invoices_insert" ON public.invoices;
CREATE POLICY "invoices_insert" ON public.invoices
  FOR INSERT WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      uploaded_by = auth.uid()
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
  );

-- 3) 发票更新：super_admin 全部；admin 仅本公司；成员仅本人 draft/rejected
DROP POLICY IF EXISTS "invoices_update_admin" ON public.invoices;
DROP POLICY IF EXISTS "invoices_update_member" ON public.invoices;
CREATE POLICY "invoices_update_admin" ON public.invoices
  FOR UPDATE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'admin')
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
  )
  WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'admin')
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
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

-- 4) 删除：super_admin 全部；admin 仅本公司
DROP POLICY IF EXISTS "invoices_delete" ON public.invoices;
CREATE POLICY "invoices_delete" ON public.invoices
  FOR DELETE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'admin')
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
  );

-- 5) 公司：服务角色/超管全部；其余仅自己所属公司
DROP POLICY IF EXISTS "companies_read" ON public.companies;
CREATE POLICY "companies_read" ON public.companies
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
  );

-- 6) 档案：本人/超管全部；admin 仅同公司用户（用 SECURITY DEFINER 避免策略递归）
CREATE OR REPLACE FUNCTION public.current_user_sees_profile(p_id UUID)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $fn$
  SELECT auth.role() = 'service_role'
    OR auth.uid() = p_id
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'super_admin')
    OR (
      EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
      AND EXISTS (
        SELECT 1
        FROM public.user_companies uc1
        JOIN public.user_companies uc2 ON uc1.company_id = uc2.company_id
        WHERE uc1.user_id = auth.uid() AND uc2.user_id = p_id
      )
    );
$fn$;

DROP POLICY IF EXISTS "profiles_read" ON public.profiles;
CREATE POLICY "profiles_read" ON public.profiles
  FOR SELECT USING (public.current_user_sees_profile(id));

-- 7) 报表：超管全部；admin 仅本公司；成员不可见
DROP POLICY IF EXISTS "reports_select" ON public.expense_reports;
CREATE POLICY "reports_select" ON public.expense_reports
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'admin')
      AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
    )
  );

-- 8) Storage：super_admin 全部；admin 仅本公司发票文件；成员仅本人发票文件
DROP POLICY IF EXISTS "storage_objects_select" ON storage.objects;
CREATE POLICY "storage_objects_select" ON storage.objects
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      bucket_id = 'invoices'
      AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE (
          i.uploaded_by = auth.uid()
          OR (
            auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'admin')
            AND i.company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
          )
        )
        AND (i.storage_path = storage.objects.name
             OR i.storage_path = 'invoices/' || storage.objects.name)
      )
    )
  );

DROP POLICY IF EXISTS "storage_objects_insert" ON storage.objects;
CREATE POLICY "storage_objects_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      bucket_id = 'invoices'
      AND (storage.foldername(name))[1] IN (
        SELECT company_id::text FROM public.user_companies WHERE user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS "storage_objects_update" ON storage.objects;
CREATE POLICY "storage_objects_update" ON storage.objects
  FOR UPDATE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      bucket_id = 'invoices'
      AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
          AND (i.storage_path = storage.objects.name
               OR i.storage_path = 'invoices/' || storage.objects.name)
      )
    )
  )
  WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      bucket_id = 'invoices'
      AND (storage.foldername(name))[1] IN (
        SELECT company_id::text FROM public.user_companies WHERE user_id = auth.uid()
      )
    )
  );

DROP POLICY IF EXISTS "storage_objects_delete" ON storage.objects;
CREATE POLICY "storage_objects_delete" ON storage.objects
  FOR DELETE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR (
      bucket_id = 'invoices'
      AND EXISTS (
        SELECT 1
        FROM public.invoices i
        WHERE i.company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
          AND (i.storage_path = storage.objects.name
               OR i.storage_path = 'invoices/' || storage.objects.name)
      )
    )
  );

COMMIT;
