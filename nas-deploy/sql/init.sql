-- ============================================================
-- ECS 报销管理系统 - 数据库初始化
-- v3.1
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. 先创建角色
CREATE ROLE anon NOLOGIN NOINHERIT;
CREATE ROLE authenticated NOLOGIN NOINHERIT;
CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'ecs_supabase_2026';
GRANT anon TO authenticator;
GRANT authenticated TO authenticator;

-- 2. 创建 schema
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_admin;
CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION supabase_admin;
GRANT USAGE ON SCHEMA auth TO anon, authenticated;
GRANT ALL ON SCHEMA auth TO supabase_admin;

-- 3. auth.uid() 和 auth.role()
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auth.role() RETURNS text AS $$
  SELECT nullif(current_setting('request.jwt.claim.role', true), '')::text;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated;

-- 4. 业务表
CREATE TABLE IF NOT EXISTS expense_categories (
  id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE,
  description TEXT, sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS invoices (
  id BIGSERIAL PRIMARY KEY,
  storage_path TEXT NOT NULL, original_filename TEXT NOT NULL, file_size INTEGER,
  invoice_number TEXT, invoice_date DATE,
  buyer_name TEXT, buyer_tax_id TEXT,
  seller_name TEXT, seller_tax_id TEXT,
  item_description TEXT, amount DECIMAL(12,2), tax_amount DECIMAL(12,2), total_amount DECIMAL(12,2),
  category_id BIGINT REFERENCES expense_categories(id),
  project_location TEXT, expense_note TEXT, expense_date DATE,
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  raw_ocr_text TEXT, ocr_confidence REAL, uploaded_by UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(), updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_invoices_date ON invoices(invoice_date);
CREATE INDEX IF NOT EXISTS idx_invoices_category ON invoices(category_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_uploader ON invoices(uploaded_by);

CREATE TABLE IF NOT EXISTS expense_reports (
  id BIGSERIAL PRIMARY KEY,
  report_type TEXT NOT NULL CHECK (report_type IN ('monthly','quarterly','annual')),
  period_key TEXT NOT NULL, total_amount DECIMAL(14,2) DEFAULT 0,
  invoice_count INTEGER DEFAULT 0, category_breakdown JSONB,
  generated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(report_type, period_key)
);
ALTER TABLE expense_reports ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY, email TEXT, name TEXT,
  role TEXT CHECK (role IN ('member', 'admin', 'super_admin')),
  status TEXT DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- storage 系统表
CREATE TABLE IF NOT EXISTS storage.buckets (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, owner UUID,
  created_at TIMESTAMPTZ DEFAULT NOW(), updated_at TIMESTAMPTZ DEFAULT NOW(),
  public BOOLEAN DEFAULT FALSE
);
CREATE TABLE IF NOT EXISTS storage.objects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id TEXT REFERENCES storage.buckets(id),
  name TEXT, owner UUID, created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(), last_accessed_at TIMESTAMPTZ DEFAULT NOW(),
  metadata JSONB, path_tokens TEXT[]
);

-- 5. RLS 策略
CREATE POLICY "authenticated_all" ON expense_categories FOR ALL USING (auth.role() = 'authenticated');
CREATE POLICY "authenticated_all" ON invoices FOR ALL USING (auth.role() = 'authenticated');
CREATE POLICY "authenticated_all" ON expense_reports FOR ALL USING (auth.role() = 'authenticated');
CREATE POLICY "authenticated_all" ON profiles FOR ALL USING (auth.role() = 'authenticated');

-- 6. 自动创建档案触发器
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, name, role, status)
  VALUES (NEW.id, NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'role', 'super_admin'), 'active');
  RETURN NEW;
END;
$$;

-- 7. RPC 函数
CREATE OR REPLACE FUNCTION refresh_expense_report(p_type TEXT, p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB; v_total DECIMAL(14,2); v_count INTEGER; v_breakdown JSONB;
BEGIN
  IF p_type = 'monthly' THEN
    SELECT COALESCE(SUM(total_amount),0), COUNT(*) INTO v_total, v_count
    FROM invoices WHERE TO_CHAR(invoice_date,'YYYY-MM') = p_key AND status = 'approved';
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name, COALESCE(SUM(i.total_amount),0) as amt
      FROM invoices i JOIN expense_categories c ON i.category_id=c.id
      WHERE TO_CHAR(i.invoice_date,'YYYY-MM')=p_key AND i.status='approved' GROUP BY c.name) sub;
  ELSIF p_type = 'quarterly' THEN
    SELECT COALESCE(SUM(total_amount),0), COUNT(*) INTO v_total, v_count
    FROM invoices WHERE EXTRACT(YEAR FROM invoice_date)=SPLIT_PART(p_key,'-',1)::INT
      AND CEIL(EXTRACT(MONTH FROM invoice_date)/3.0)=SPLIT_PART(p_key,'-',2)::INT AND status='approved';
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name, COALESCE(SUM(i.total_amount),0) as amt
      FROM invoices i JOIN expense_categories c ON i.category_id=c.id
      WHERE EXTRACT(YEAR FROM i.invoice_date)=SPLIT_PART(p_key,'-',1)::INT
        AND CEIL(EXTRACT(MONTH FROM i.invoice_date)/3.0)=SPLIT_PART(p_key,'-',2)::INT
        AND i.status='approved' GROUP BY c.name) sub;
  ELSE
    SELECT COALESCE(SUM(total_amount),0), COUNT(*) INTO v_total, v_count
    FROM invoices WHERE EXTRACT(YEAR FROM invoice_date)=p_key::INT AND status='approved';
    SELECT JSONB_OBJECT_AGG(c.name, sub.amt) INTO v_breakdown
    FROM (SELECT c.name, COALESCE(SUM(i.total_amount),0) as amt
      FROM invoices i JOIN expense_categories c ON i.category_id=c.id
      WHERE EXTRACT(YEAR FROM i.invoice_date)=p_key::INT AND i.status='approved' GROUP BY c.name) sub;
  END IF;
  INSERT INTO expense_reports (report_type,period_key,total_amount,invoice_count,category_breakdown)
  VALUES (p_type,p_key,v_total,v_count,v_breakdown)
  ON CONFLICT (report_type,period_key) DO UPDATE SET
    total_amount=EXCLUDED.total_amount, invoice_count=EXCLUDED.invoice_count,
    category_breakdown=EXCLUDED.category_breakdown, generated_at=NOW();
  RETURN JSONB_BUILD_OBJECT('type',p_type,'period',p_key,'total',v_total,'count',v_count,'breakdown',v_breakdown);
END;
$$;

CREATE OR REPLACE FUNCTION insert_invoice(
  p_storage_path TEXT, p_original_filename TEXT, p_file_size INTEGER,
  p_category_id BIGINT, p_project_location TEXT, p_uploaded_by UUID,
  p_status TEXT DEFAULT 'pending')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO invoices (storage_path, original_filename, file_size, category_id, project_location, uploaded_by, status)
  VALUES (p_storage_path, p_original_filename, p_file_size, p_category_id, p_project_location, p_uploaded_by, p_status);
  RETURN JSONB_BUILD_OBJECT('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION admin_create_profile(p_id UUID, p_email TEXT, p_name TEXT, p_role TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
  INSERT INTO profiles (id, email, name, role, status)
  VALUES (p_id, p_email, p_name, p_role, 'active')
  ON CONFLICT (id) DO UPDATE SET email=EXCLUDED.email, name=EXCLUDED.name, role=EXCLUDED.role;
$$;

CREATE OR REPLACE FUNCTION admin_update_user_status(user_id UUID, new_status TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
  UPDATE profiles SET status = new_status WHERE id = user_id;
$$;

-- 8. 默认类目
INSERT INTO expense_categories (name, description, sort_order) VALUES
  ('办公用品','办公用品采购',1),('出差餐饮费','出差期间的餐饮支出',2),
  ('出差交通费','出差交通支出（机票、高铁、打车等）',3),('出差住房费','出差住宿支出',4),
  ('客情餐饮费','客户/客情关系维护餐饮支出',5),('日常餐饮费','日常团队餐饮支出',6),
  ('通讯费','手机话费等通讯支出',7),('外出交通费','本地外出交通支出（打车、地铁等）',8)
ON CONFLICT (name) DO NOTHING;

-- 9. storage bucket
INSERT INTO storage.buckets (id, name, public) VALUES ('invoices', 'invoices', false)
ON CONFLICT (id) DO NOTHING;
