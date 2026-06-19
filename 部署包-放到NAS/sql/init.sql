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
-- ============ auth 函数桩（GoTrue 迁移后会覆盖）============
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text AS $$
  SELECT nullif(current_setting('request.jwt.claim.role', true), '')::text;
$$ LANGUAGE sql STABLE SECURITY DEFINER;



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
CREATE POLICY "authenticated_all_objects" ON storage.objects FOR ALL USING (auth.role() = 'authenticated');
CREATE POLICY "service_all_objects" ON storage.objects FOR ALL USING (auth.role() = 'service_role');

-- ============ 业务表 ============
CREATE TABLE IF NOT EXISTS public.expense_categories (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
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
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
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

-- ============ RLS 策略 ============
CREATE POLICY "authenticated_all" ON public.expense_categories FOR ALL USING (auth.role() IN ('authenticated','service_role'));
CREATE POLICY "authenticated_all" ON public.invoices FOR ALL USING (auth.role() IN ('authenticated','service_role'));
CREATE POLICY "authenticated_all" ON public.expense_reports FOR ALL USING (auth.role() IN ('authenticated','service_role'));
CREATE POLICY "authenticated_all" ON public.profiles FOR ALL USING (auth.role() IN ('authenticated','service_role'));

-- ============ 表权限 ============
GRANT SELECT, INSERT, UPDATE, DELETE ON public.expense_categories TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.invoices TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.expense_reports TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles TO authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

-- ============ RPC 函数 ============
CREATE OR REPLACE FUNCTION public.refresh_expense_report(p_type TEXT, p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_total DECIMAL(14,2); v_count INTEGER; v_breakdown JSONB;
BEGIN
  IF p_type='monthly' THEN
    SELECT COALESCE(SUM(total_amount),0),COUNT(*) INTO v_total,v_count
    FROM public.invoices WHERE TO_CHAR(invoice_date,'YYYY-MM')=p_key AND status='approved';
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name,COALESCE(SUM(i.total_amount),0) amt
          FROM public.invoices i JOIN public.expense_categories c ON i.category_id=c.id
          WHERE TO_CHAR(i.invoice_date,'YYYY-MM')=p_key AND i.status='approved'
          GROUP BY c.name) sub;
  ELSIF p_type='quarterly' THEN
    SELECT COALESCE(SUM(total_amount),0),COUNT(*) INTO v_total,v_count
    FROM public.invoices
    WHERE EXTRACT(YEAR FROM invoice_date)=SPLIT_PART(p_key,'-',1)::INT
      AND CEIL(EXTRACT(MONTH FROM invoice_date)/3.0)=SPLIT_PART(p_key,'-',2)::INT
      AND status='approved';
  ELSE
    SELECT COALESCE(SUM(total_amount),0),COUNT(*) INTO v_total,v_count
    FROM public.invoices WHERE EXTRACT(YEAR FROM invoice_date)=p_key::INT AND status='approved';
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name,COALESCE(SUM(i.total_amount),0) amt
          FROM public.invoices i JOIN public.expense_categories c ON i.category_id=c.id
          WHERE EXTRACT(YEAR FROM i.invoice_date)=p_key::INT AND i.status='approved'
          GROUP BY c.name) sub;
  END IF;
  INSERT INTO public.expense_reports(report_type,period_key,total_amount,invoice_count,category_breakdown)
  VALUES(p_type,p_key,v_total,v_count,v_breakdown)
  ON CONFLICT(report_type,period_key) DO UPDATE
  SET total_amount=EXCLUDED.total_amount,invoice_count=EXCLUDED.invoice_count,
      category_breakdown=EXCLUDED.category_breakdown,generated_at=NOW();
  RETURN JSONB_BUILD_OBJECT('type',p_type,'period',p_key,'total',v_total,'count',v_count,'breakdown',v_breakdown);
END; $$;

CREATE OR REPLACE FUNCTION public.insert_invoice(storage_path TEXT, original_filename TEXT, file_size INTEGER, invoice_date TEXT DEFAULT NULL, category_id BIGINT DEFAULT NULL, project_location TEXT DEFAULT NULL, uploaded_by UUID DEFAULT NULL, status TEXT DEFAULT 'pending')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_date DATE;
BEGIN
  v_date := COALESCE(invoice_date::DATE, CURRENT_DATE);
  INSERT INTO public.invoices(storage_path,original_filename,file_size,category_id,project_location,uploaded_by,status,invoice_date)
  VALUES(storage_path,original_filename,file_size,category_id,project_location,uploaded_by,status,v_date);
  RETURN JSONB_BUILD_OBJECT('success',true);
END; $$;

CREATE OR REPLACE FUNCTION public.admin_create_profile(p_id UUID, p_email TEXT, p_name TEXT, p_role TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles(id,email,name,role,status) VALUES(p_id,p_email,p_name,p_role,'active')
  ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;
END; $$;

CREATE OR REPLACE FUNCTION public.admin_update_user_status(user_id UUID, new_status TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.profiles SET status=new_status WHERE id=user_id;
END; $$;

-- ============ 默认数据 ============
INSERT INTO public.expense_categories (name, description, sort_order) VALUES
  ('办公用品','办公用品采购',1),
  ('出差餐饮费','出差期间的餐饮支出',2),
  ('出差交通费','出差交通支出',3),
  ('出差住房费','出差住宿支出',4),
  ('客情餐饮费','客情关系维护餐饮支出',5),
  ('日常餐饮费','日常团队餐饮支出',6),
  ('通讯费','手机话费等通讯支出',7),
  ('外出交通费','本地外出交通支出',8)
ON CONFLICT (name) DO NOTHING;
