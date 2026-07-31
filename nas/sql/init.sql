-- ECS v4.4 - GoTrue auto-migrate（含 auth.uid/role 桩函数，供 RLS 策略使用）
-- Schema、角色、扩展由 init.sql 创建；auth 表由 GoTrue 自动迁移

-- ============ 扩展 ============
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;

-- ============ 角色 ============
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticator') THEN CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'ecs_supabase_2026';
  ELSE ALTER ROLE authenticator WITH LOGIN PASSWORD 'ecs_supabase_2026'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_admin') THEN CREATE ROLE supabase_admin LOGIN SUPERUSER PASSWORD 'ecs_supabase_2026';
  ELSE ALTER ROLE supabase_admin WITH LOGIN SUPERUSER PASSWORD 'ecs_supabase_2026'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_auth_admin') THEN CREATE ROLE supabase_auth_admin LOGIN PASSWORD 'ecs_supabase_2026';
  ELSE ALTER ROLE supabase_auth_admin WITH LOGIN PASSWORD 'ecs_supabase_2026'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_storage_admin') THEN CREATE ROLE supabase_storage_admin LOGIN PASSWORD 'ecs_supabase_2026';
  ELSE ALTER ROLE supabase_storage_admin WITH LOGIN PASSWORD 'ecs_supabase_2026'; END IF;
  -- ★ GoTrue migration 需要 postgres 角色
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='postgres') THEN CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'ecs_supabase_2026';
  ELSE ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'ecs_supabase_2026'; END IF;
END;
$$;
GRANT anon TO authenticator;
GRANT authenticated TO authenticator;
GRANT service_role TO authenticator;

-- ============ Schema ============
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;
ALTER SCHEMA auth OWNER TO supabase_admin;
ALTER SCHEMA storage OWNER TO supabase_admin;
GRANT USAGE, CREATE ON SCHEMA auth TO supabase_admin, supabase_auth_admin;
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role;
GRANT USAGE, CREATE ON SCHEMA storage TO supabase_admin, supabase_storage_admin, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON TABLES TO supabase_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON SEQUENCES TO supabase_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT ALL ON FUNCTIONS TO supabase_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON TABLES TO authenticated, supabase_storage_admin, supabase_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON SEQUENCES TO supabase_storage_admin, supabase_admin;
-- ============ auth 函数桩（GoTrue 迁移后会覆盖；本版本修复空字符串转 uuid 报错）============
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



-- ============ Storage 核心表（storage-api v1.60 手动创建，防止迁移失败）============
CREATE TABLE IF NOT EXISTS storage.buckets (
    id text NOT NULL,
    name text NOT NULL UNIQUE,
    owner uuid,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    public boolean DEFAULT false,
    avif_autodetection boolean DEFAULT false,
    file_size_limit bigint,
    allowed_mime_types text[],
    PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS storage.objects (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    bucket_id text,
    name text,
    owner uuid,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    last_accessed_at timestamptz DEFAULT now(),
    metadata jsonb,
    PRIMARY KEY (id),
    UNIQUE (bucket_id, name)
);

CREATE TABLE IF NOT EXISTS storage.s3_multipart_uploads (
    id text NOT NULL,
    in_progress_size bigint DEFAULT 0,
    upload_signature text NOT NULL,
    bucket_id text NOT NULL,
    key text NOT NULL,
    version text NOT NULL,
    owner_id text,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (id)
);

CREATE TABLE IF NOT EXISTS storage.s3_multipart_uploads_parts (
    id uuid DEFAULT extensions.uuid_generate_v4() NOT NULL,
    upload_id text NOT NULL REFERENCES storage.s3_multipart_uploads(id) ON DELETE CASCADE,
    size bigint DEFAULT 0,
    part_number integer NOT NULL,
    key_version text NOT NULL,
    etag text NOT NULL,
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (id)
);

-- ============ Storage 策略 ============
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.s3_multipart_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.s3_multipart_uploads_parts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_all_buckets" ON storage.buckets FOR ALL USING (auth.role() = 'authenticated');
CREATE POLICY "service_all_buckets" ON storage.buckets FOR ALL USING (auth.role() = 'service_role');
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
CREATE POLICY "storage_objects_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
    OR (
      bucket_id = 'invoices'
      AND (storage.foldername(name))[1] IN (
        SELECT company_id::text FROM public.user_companies WHERE user_id = auth.uid()
      )
    )
  );
CREATE POLICY "storage_objects_update" ON storage.objects
  FOR UPDATE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  )
  WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  );
CREATE POLICY "storage_objects_delete" ON storage.objects
  FOR DELETE USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  );
CREATE POLICY "service_all_objects" ON storage.objects FOR ALL USING (auth.role() = 'service_role');

-- ============ 业务表 ============
CREATE TABLE IF NOT EXISTS public.expense_categories (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    financial_category TEXT,
    description TEXT,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.invoices (
    id BIGSERIAL PRIMARY KEY,
    storage_path TEXT,
    original_filename TEXT,
    file_size INTEGER DEFAULT 0,
    category_id BIGINT REFERENCES public.expense_categories(id),
    project_location TEXT,
    invoice_number TEXT,
    invoice_date DATE,
    seller_name TEXT,
    total_amount DECIMAL(14,2),
    raw_ocr_text TEXT,
    uploaded_by UUID,
    status TEXT DEFAULT 'draft' CHECK (status IN ('draft','pending','approved','rejected')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.expense_reports (
    id BIGSERIAL PRIMARY KEY,
    report_type TEXT NOT NULL CHECK (report_type IN ('monthly','quarterly','annual')),
    period_key TEXT NOT NULL,
    total_amount DECIMAL(14,2) DEFAULT 0,
    invoice_count INTEGER DEFAULT 0,
    category_breakdown JSONB,
    generated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(report_type, period_key)
);
ALTER TABLE public.expense_reports ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY,
    email TEXT,
    name TEXT,
    role TEXT CHECK (role IN ('member','admin','super_admin')),
    status TEXT DEFAULT 'active',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ============ v3.0 多公司 + 用户管理 ============
CREATE TABLE IF NOT EXISTS public.companies (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    short_name TEXT,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.user_companies (
    user_id UUID NOT NULL,
    company_id BIGINT NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (user_id, company_id)
);
ALTER TABLE public.user_companies ENABLE ROW LEVEL SECURITY;

-- v3.0 ADD COLUMN company_id（放在 companies 表创建之后）
ALTER TABLE public.invoices ADD COLUMN IF NOT EXISTS company_id BIGINT REFERENCES public.companies(id);
CREATE INDEX IF NOT EXISTS idx_invoices_company ON public.invoices(company_id);
ALTER TABLE public.expense_reports ADD COLUMN IF NOT EXISTS company_id BIGINT REFERENCES public.companies(id);

-- ============ RLS 策略 ============
DROP POLICY IF EXISTS "authenticated_all" ON public.expense_categories;
DROP POLICY IF EXISTS "authenticated_all" ON public.invoices;
DROP POLICY IF EXISTS "authenticated_all" ON public.expense_reports;
DROP POLICY IF EXISTS "authenticated_all" ON public.profiles;

-- 新用户自动创建 member 档案（禁止自动提权）
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  INSERT INTO public.profiles(id, email, name, role, status)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NULLIF(NEW.raw_user_meta_data->>'name',''), split_part(NEW.email,'@',1)),
    'member',
    'active'
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- RLS 辅助函数：以 definer 身份判断当前用户是否管理员（避免策略自引用递归）
CREATE OR REPLACE FUNCTION public.current_user_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin','super_admin'));
$fn$;

-- 普通用户禁止审批：只有管理员/服务角色能修改状态为通过或驳回
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

DROP TRIGGER IF EXISTS trg_invoices_member_status ON public.invoices;
CREATE TRIGGER trg_invoices_member_status
  BEFORE UPDATE ON public.invoices
  FOR EACH ROW EXECUTE FUNCTION public.prevent_member_status_change();

-- 费用类目：成员只读，管理员可写
CREATE POLICY "categories_read" ON public.expense_categories
  FOR SELECT USING (auth.role() IN ('authenticated','service_role'));
CREATE POLICY "categories_write" ON public.expense_categories
  FOR ALL USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  )
  WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  );

-- companies：成员只看所属公司，管理员可看全部
CREATE POLICY "companies_read" ON public.companies
  FOR SELECT USING (
    auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
    OR id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
  );
CREATE POLICY "companies_write" ON public.companies
  FOR ALL USING (auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin'));

-- user_companies：本用户可读，super_admin/admin 可写
CREATE POLICY "user_companies_read" ON public.user_companies
  FOR SELECT USING (
    auth.uid() = user_id
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('super_admin','admin'))
  );
CREATE POLICY "user_companies_write" ON public.user_companies
  FOR ALL USING (
    auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('super_admin','admin'))
  );

-- invoices：成员只看自己上传的，管理员/service_role 看全部
CREATE POLICY "invoices_select" ON public.invoices FOR SELECT USING (
  auth.role() = 'service_role'
  OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  OR uploaded_by = auth.uid()
);
CREATE POLICY "invoices_insert" ON public.invoices FOR INSERT WITH CHECK (
  auth.role() = 'service_role'
  OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
  OR (
    uploaded_by = auth.uid()
    AND company_id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
  )
);
CREATE POLICY "invoices_update_admin" ON public.invoices FOR UPDATE USING (
  auth.role() = 'service_role'
  OR
  auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
)
WITH CHECK (
  auth.role() = 'service_role'
  OR
  auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
);
CREATE POLICY "invoices_update_member" ON public.invoices FOR UPDATE USING (
  uploaded_by = auth.uid()
  AND status IN ('draft','rejected')
)
WITH CHECK (
  uploaded_by = auth.uid()
  AND status IN ('draft','rejected','pending')
);
CREATE POLICY "invoices_delete" ON public.invoices FOR DELETE USING (
  auth.role() = 'service_role'
  OR
  auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
);

-- expense_reports：仅管理员/服务角色可见
CREATE POLICY "reports_select" ON public.expense_reports FOR SELECT USING (
  auth.role() = 'service_role'
  OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('admin','super_admin'))
);
CREATE POLICY "reports_write" ON public.expense_reports FOR ALL USING (
  auth.role() = 'service_role'
  OR auth.uid() IN (SELECT id FROM public.profiles WHERE role IN ('super_admin','admin'))
);

-- profiles：成员只看自己的档案，管理员可看全部；插入/更新/删除仅限管理员
CREATE POLICY "profiles_read" ON public.profiles FOR SELECT USING (
  auth.uid() = id
  OR public.current_user_is_admin()
  OR auth.role() = 'service_role'
);
CREATE POLICY "profiles_insert_admin" ON public.profiles FOR INSERT WITH CHECK (
  public.current_user_is_admin()
  OR auth.role() = 'service_role'
);
CREATE POLICY "profiles_update_admin" ON public.profiles FOR UPDATE USING (
  public.current_user_is_admin()
  OR auth.role() = 'service_role'
);
CREATE POLICY "profiles_delete_admin" ON public.profiles FOR DELETE USING (
  public.current_user_is_admin()
  OR auth.role() = 'service_role'
);

-- ============ 表权限 ============
GRANT SELECT, INSERT, UPDATE, DELETE ON public.expense_categories TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoices TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.expense_reports TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.companies TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_companies TO authenticated, service_role;

-- ============ RPC 函数 ============
CREATE OR REPLACE FUNCTION public.is_admin_or_service()
RETURNS boolean LANGUAGE sql STABLE AS $fn$
  SELECT auth.role() = 'service_role'
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin','super_admin'));
$fn$;

CREATE OR REPLACE FUNCTION public.refresh_expense_report(p_type TEXT, p_key TEXT, p_company_id BIGINT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_total DECIMAL(14,2); v_count INTEGER; v_breakdown JSONB;
BEGIN
  IF auth.role() <> 'service_role'
     AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin','super_admin')) THEN
    IF p_company_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM public.user_companies WHERE user_id = auth.uid() AND company_id = p_company_id) THEN
      RAISE EXCEPTION '无权查看该公司报表';
    END IF;
  END IF;

  IF p_type='monthly' THEN
    SELECT COALESCE(SUM(total_amount),0),COUNT(*) INTO v_total,v_count
    FROM public.invoices WHERE TO_CHAR(invoice_date,'YYYY-MM')=p_key AND status='approved'
      AND (p_company_id IS NULL OR company_id=p_company_id);
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name,COALESCE(SUM(i.total_amount),0) amt
          FROM public.invoices i JOIN public.expense_categories c ON i.category_id=c.id
          WHERE TO_CHAR(i.invoice_date,'YYYY-MM')=p_key AND i.status='approved'
            AND (p_company_id IS NULL OR i.company_id=p_company_id)
          GROUP BY c.name) sub;
  ELSIF p_type='quarterly' THEN
    SELECT COALESCE(SUM(total_amount),0),COUNT(*) INTO v_total,v_count
    FROM public.invoices
    WHERE EXTRACT(YEAR FROM invoice_date)=SPLIT_PART(p_key,'-',1)::INT
      AND CEIL(EXTRACT(MONTH FROM invoice_date)/3.0)=SPLIT_PART(p_key,'-',2)::INT
      AND status='approved'
      AND (p_company_id IS NULL OR company_id=p_company_id);
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name,COALESCE(SUM(i.total_amount),0) amt
          FROM public.invoices i JOIN public.expense_categories c ON i.category_id=c.id
          WHERE EXTRACT(YEAR FROM i.invoice_date)=SPLIT_PART(p_key,'-',1)::INT
            AND CEIL(EXTRACT(MONTH FROM i.invoice_date)/3.0)=SPLIT_PART(p_key,'-',2)::INT
            AND i.status='approved'
            AND (p_company_id IS NULL OR i.company_id=p_company_id)
          GROUP BY c.name) sub;
  ELSE
    SELECT COALESCE(SUM(total_amount),0),COUNT(*) INTO v_total,v_count
    FROM public.invoices WHERE EXTRACT(YEAR FROM invoice_date)=p_key::INT AND status='approved'
      AND (p_company_id IS NULL OR company_id=p_company_id);
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name,COALESCE(SUM(i.total_amount),0) amt
          FROM public.invoices i JOIN public.expense_categories c ON i.category_id=c.id
          WHERE EXTRACT(YEAR FROM i.invoice_date)=p_key::INT AND i.status='approved'
            AND (p_company_id IS NULL OR i.company_id=p_company_id)
          GROUP BY c.name) sub;
  END IF;
  INSERT INTO public.expense_reports(report_type,period_key,total_amount,invoice_count,category_breakdown,company_id)
  VALUES(p_type,p_key,v_total,v_count,v_breakdown,p_company_id)
  ON CONFLICT(report_type,period_key,company_id) DO UPDATE
  SET total_amount=EXCLUDED.total_amount,invoice_count=EXCLUDED.invoice_count,
      category_breakdown=EXCLUDED.category_breakdown,generated_at=NOW();
  RETURN JSONB_BUILD_OBJECT('type',p_type,'period',p_key,'total',v_total,'count',v_count,'breakdown',v_breakdown);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_assign_user_companies(
  p_user_id UUID, p_company_ids BIGINT[]
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NOT public.is_admin_or_service() THEN
    RAISE EXCEPTION '无用户管理权限';
  END IF;
  DELETE FROM public.user_companies WHERE user_id = p_user_id;
  IF p_company_ids IS NOT NULL AND cardinality(p_company_ids) > 0 THEN
    INSERT INTO public.user_companies (user_id, company_id)
    SELECT p_user_id, unnest(p_company_ids);
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_invite_user(p_email TEXT, p_name TEXT, p_role TEXT, p_company_ids BIGINT[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
  v_uid UUID;
  v_password TEXT;
  v_hash TEXT;
  v_existing boolean := false;
BEGIN
  IF NOT public.is_admin_or_service() THEN
    RAISE EXCEPTION '无用户管理权限';
  END IF;
  p_email := lower(btrim(p_email));
  IF p_email = '' THEN RAISE EXCEPTION '邮箱不能为空'; END IF;
  IF p_role NOT IN ('member','admin') THEN RAISE EXCEPTION '非法角色'; END IF;

  SELECT id INTO v_uid FROM auth.users WHERE lower(email) = p_email LIMIT 1;
  IF FOUND THEN
    v_existing := true;
  ELSE
    v_uid := extensions.gen_random_uuid();
    v_password := encode(extensions.gen_random_bytes(9), 'hex');
    v_hash := extensions.crypt(v_password, extensions.gen_salt('bf', 10));
    INSERT INTO auth.users(
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, confirmation_token, recovery_token,
      email_change_token_new, email_change,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at, is_super_admin, is_sso_user, is_anonymous
    ) VALUES (
      '00000000-0000-0000-0000-000000000000', v_uid, '', 'authenticated', p_email, v_hash,
      now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('name', p_name),
      now(), now(), false, false, false
    );
    INSERT INTO auth.identities(
      provider_id, user_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      v_uid::text, v_uid,
      jsonb_build_object('sub', v_uid::text, 'email', p_email, 'email_verified', true, 'phone_verified', false),
      'email', now(), now(), now()
    );
  END IF;

  INSERT INTO public.profiles(id, email, name, role, status)
  VALUES (v_uid, p_email, COALESCE(NULLIF(p_name,''), split_part(p_email,'@',1)), p_role, 'active')
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email, name = EXCLUDED.name, role = EXCLUDED.role, status = 'active';

  DELETE FROM public.user_companies WHERE user_id = v_uid;
  IF p_company_ids IS NOT NULL AND cardinality(p_company_ids) > 0 THEN
    INSERT INTO public.user_companies(user_id, company_id)
    SELECT v_uid, unnest(p_company_ids)
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_existing THEN
    RETURN jsonb_build_object('user_id', v_uid::text, 'created', false, 'existing', true);
  END IF;
  RETURN jsonb_build_object('user_id', v_uid::text, 'password', v_password, 'created', true, 'existing', false);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.ensure_my_profile(p_id UUID, p_email TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF (p_id IS NULL OR p_id <> auth.uid()) AND auth.role() <> 'service_role' THEN
    RAISE EXCEPTION '只能创建自己的档案';
  END IF;
  INSERT INTO public.profiles(id, email, name, role, status)
  VALUES (p_id, p_email, split_part(COALESCE(p_email,''),'@',1), 'member', 'active')
  ON CONFLICT (id) DO NOTHING;
END;
$fn$;

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

CREATE OR REPLACE FUNCTION public.delete_invoice(p_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_storage_path TEXT;
BEGIN
  IF NOT public.is_admin_or_service() THEN
    RAISE EXCEPTION '无删除权限';
  END IF;
  SELECT storage_path INTO v_storage_path FROM public.invoices WHERE id = p_id;
  DELETE FROM public.invoices WHERE id = p_id;
  RETURN JSONB_BUILD_OBJECT('success', true, 'storage_path', v_storage_path);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_create_profile(p_id UUID, p_email TEXT, p_name TEXT, p_role TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NOT public.is_admin_or_service() THEN
    RAISE EXCEPTION '无用户管理权限';
  END IF;
  INSERT INTO public.profiles(id,email,name,role,status)
  VALUES(
    p_id,
    COALESCE(NULLIF(p_email,''), (SELECT email FROM public.profiles WHERE id = p_id)),
    p_name,
    p_role,
    'active'
  )
  ON CONFLICT(id) DO UPDATE SET
    email = COALESCE(NULLIF(EXCLUDED.email,''), public.profiles.email),
    name = EXCLUDED.name,
    role = EXCLUDED.role;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_update_user_status(user_id UUID, new_status TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $fn$
BEGIN
  IF NOT public.is_admin_or_service() THEN
    RAISE EXCEPTION '无用户管理权限';
  END IF;
  UPDATE public.profiles SET status=new_status WHERE id=user_id;
END;
$fn$;

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

-- 保证 invoices bucket 存在
INSERT INTO storage.buckets(id, name, public, file_size_limit)
VALUES ('invoices', 'invoices', false, 52428800)
ON CONFLICT (id) DO NOTHING;

-- ============ 默认数据 ============
INSERT INTO public.expense_categories (name, financial_category, description, sort_order) VALUES
  ('办公用品','办公费','办公用品采购',1),
  ('出差餐饮费','差旅费','出差期间的餐饮支出',2),
  ('出差交通费','差旅费','出差交通支出',3),
  ('出差住房费','差旅费','出差住宿支出',4),
  ('客情餐饮费','招待费','客情关系维护餐饮支出',5),
  ('日常餐饮费','福利费','日常团队餐饮支出',6),
  ('通讯费','通讯费','手机话费等通讯支出',7),
  ('外出交通费','差旅费','本地外出交通支出',8),
  ('商务应酬','招待费','商务招待及应酬支出',9)
ON CONFLICT (name) DO NOTHING;

-- v3.0 公司种子数据
INSERT INTO public.companies (name, short_name, sort_order) VALUES
  ('广州逸创网络有限公司', '逸创网络', 1),
  ('广州逸创奥网络科技有限公司', '逸创奥', 2)
ON CONFLICT (name) DO NOTHING;

-- v3.0 迁移：已有数据归入第一家
UPDATE public.invoices SET company_id = 1 WHERE company_id IS NULL;
UPDATE public.expense_reports SET company_id = 1 WHERE company_id IS NULL;

-- v3.0 更新 NOT NULL + 唯一约束
ALTER TABLE public.invoices ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.expense_reports ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.expense_reports DROP CONSTRAINT IF EXISTS expense_reports_report_type_period_key;
ALTER TABLE public.expense_reports ADD UNIQUE (report_type, period_key, company_id);

-- v3.0 唯一索引：同名同大小同公司视为重复
DROP INDEX IF EXISTS uq_invoices_filename_size;
CREATE UNIQUE INDEX IF NOT EXISTS uq_invoices_filename_size_company ON public.invoices (original_filename, file_size, company_id);

-- ============ v4.15 审批中心权限（覆盖上面的策略） ============
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

DROP POLICY IF EXISTS "companies_read" ON public.companies;
CREATE POLICY "companies_read" ON public.companies
  FOR SELECT USING (
    auth.role() = 'service_role'
    OR auth.uid() IN (SELECT id FROM public.profiles WHERE role = 'super_admin')
    OR id IN (SELECT company_id FROM public.user_companies WHERE user_id = auth.uid())
  );

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

-- ============ v4.16 OCR保持草稿 + 成员删除草稿/驳回件（覆盖上面的策略） ============
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

CREATE POLICY "invoices_delete_member" ON public.invoices
  FOR DELETE USING (
    uploaded_by = auth.uid()
    AND status IN ('draft','rejected')
  );

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
