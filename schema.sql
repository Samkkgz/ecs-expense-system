-- ============================================================
-- ECS 报销管理系统 - Supabase Schema
-- 在 Supabase SQL Editor 中运行
-- ============================================================

-- 1. 费用类目
CREATE TABLE IF NOT EXISTS expense_categories (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,        -- e.g. 办公用品, 出差餐饮费
  description TEXT,
  sort_order INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE expense_categories ENABLE ROW LEVEL SECURITY;

-- 2. 发票主表
CREATE TABLE IF NOT EXISTS invoices (
  id BIGSERIAL PRIMARY KEY,
  -- 存储信息
  storage_path TEXT NOT NULL,        -- Supabase Storage 路径 e.g. invoices/2026/06/filename.pdf
  original_filename TEXT NOT NULL,
  file_size INTEGER,
  -- 发票信息（OCR提取）
  invoice_number TEXT,               -- 发票号码
  invoice_date DATE,                 -- 开票日期
  buyer_name TEXT,                   -- 购买方名称
  buyer_tax_id TEXT,                 -- 购买方纳税人识别号
  seller_name TEXT,                  -- 销售方名称
  seller_tax_id TEXT,                -- 销售方纳税人识别号
  item_description TEXT,             -- 项目名称/摘要
  amount DECIMAL(12,2),             -- 金额（不含税）
  tax_amount DECIMAL(12,2),         -- 税额
  total_amount DECIMAL(12,2),       -- 价税合计
  -- 报销信息
  category_id BIGSERIAL REFERENCES expense_categories(id),
  project_location TEXT,             -- 项目地点 e.g. 上海, 广州, 曼谷
  expense_note TEXT,                 -- 备注说明
  expense_date DATE,                 -- 报销归属日期（默认=发票日期）
  -- 状态管理
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  -- 元数据
  raw_ocr_text TEXT,                 -- OCR原始文本
  ocr_confidence REAL,              -- OCR置信度
  uploaded_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;

-- 索引
CREATE INDEX IF NOT EXISTS idx_invoices_date ON invoices(invoice_date);
CREATE INDEX IF NOT EXISTS idx_invoices_category ON invoices(category_id);
CREATE INDEX IF NOT EXISTS idx_invoices_status ON invoices(status);
CREATE INDEX IF NOT EXISTS idx_invoices_month ON invoices(EXTRACT(YEAR FROM invoice_date), EXTRACT(MONTH FROM invoice_date));
CREATE INDEX IF NOT EXISTS idx_invoices_uploader ON invoices(uploaded_by);

-- 3. 月度/季度/年度报表缓存
CREATE TABLE IF NOT EXISTS expense_reports (
  id BIGSERIAL PRIMARY KEY,
  report_type TEXT NOT NULL CHECK (report_type IN ('monthly','quarterly','annual')),
  period_key TEXT NOT NULL,          -- '2026-06' / '2026-Q2' / '2026'
  total_amount DECIMAL(14,2) DEFAULT 0,
  invoice_count INTEGER DEFAULT 0,
  category_breakdown JSONB,         -- {"出差餐饮费": 1250.00, ...}
  generated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(report_type, period_key)
);

ALTER TABLE expense_reports ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS idx_reports_type_period ON expense_reports(report_type, period_key);

-- ============================================================
-- 6. 用户档案（复用OGD模式）
-- ============================================================
CREATE TABLE IF NOT EXISTS profiles (
  id UUID REFERENCES auth.users PRIMARY KEY,
  email TEXT,
  name TEXT,
  role TEXT CHECK (role IN ('member', 'admin', 'super_admin')),
  status TEXT DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 自动创建档案触发器
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, name, role, status)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'role', 'member'),
    'active'
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- ROW LEVEL SECURITY 策略
-- ============================================================

-- --- 费用类目：全员可读 ---
CREATE POLICY "categories_read_all"
  ON expense_categories FOR SELECT USING (true);

CREATE POLICY "categories_write_admin"
  ON expense_categories FOR ALL
  USING (auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')))
  WITH CHECK (auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')));

-- --- 发票：全员可读，可插入自己的 ---
CREATE POLICY "invoices_select_all"
  ON invoices FOR SELECT USING (true);

CREATE POLICY "invoices_insert_own"
  ON invoices FOR INSERT
  WITH CHECK (auth.uid() = uploaded_by);

CREATE POLICY "invoices_update_own_or_admin"
  ON invoices FOR UPDATE
  USING (auth.uid() = uploaded_by OR auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')))
  WITH CHECK (auth.uid() = uploaded_by OR auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')));

-- --- 报表：全员可读 ---
CREATE POLICY "reports_select_all"
  ON expense_reports FOR SELECT USING (true);

-- --- 档案策略 ---
CREATE POLICY "profiles_read_all"
  ON profiles FOR SELECT USING (true);

CREATE POLICY "profiles_insert_admin"
  ON profiles FOR INSERT
  WITH CHECK (auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')));

CREATE POLICY "profiles_update_admin"
  ON profiles FOR UPDATE
  USING (auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')))
  WITH CHECK (auth.uid() IN (SELECT id FROM profiles WHERE role IN ('admin','super_admin')));

-- ============================================================
-- RPC 函数：管理员操作
-- ============================================================
CREATE OR REPLACE FUNCTION admin_create_profile(
  p_id UUID, p_email TEXT, p_name TEXT, p_role TEXT
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
  INSERT INTO profiles (id, email, name, role, status)
  VALUES (p_id, p_email, p_name, p_role, 'pending')
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email, name = EXCLUDED.name, role = EXCLUDED.role, status = 'pending';
$$;

CREATE OR REPLACE FUNCTION admin_update_user_status(user_id UUID, new_status TEXT)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
  UPDATE profiles SET status = new_status WHERE id = user_id;
$$;

-- ============================================================
-- RPC 函数：自动生成/刷新报表
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_expense_report(p_type TEXT, p_key TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_result JSONB;
  v_total DECIMAL(14,2);
  v_count INTEGER;
  v_breakdown JSONB;
BEGIN
  IF p_type = 'monthly' THEN
    SELECT COALESCE(SUM(total_amount), 0), COUNT(*)
    INTO v_total, v_count
    FROM invoices
    WHERE TO_CHAR(invoice_date, 'YYYY-MM') = p_key
      AND status = 'approved';

    SELECT JSONB_OBJECT_AGG(c.name, sub.amt)
    INTO v_breakdown
    FROM (
      SELECT c.name, COALESCE(SUM(i.total_amount), 0) as amt
      FROM invoices i
      JOIN expense_categories c ON i.category_id = c.id
      WHERE TO_CHAR(i.invoice_date, 'YYYY-MM') = p_key
        AND i.status = 'approved'
      GROUP BY c.name
    ) sub;

  ELSIF p_type = 'quarterly' THEN
    SELECT COALESCE(SUM(total_amount), 0), COUNT(*)
    INTO v_total, v_count
    FROM invoices
    WHERE EXTRACT(YEAR FROM invoice_date) = SPLIT_PART(p_key, '-', 1)::INT
      AND CEIL(EXTRACT(MONTH FROM invoice_date) / 3.0) = SPLIT_PART(p_key, '-', 2)::INT
      AND status = 'approved';

    SELECT JSONB_OBJECT_AGG(c.name, sub.amt)
    INTO v_breakdown
    FROM (
      SELECT c.name, COALESCE(SUM(i.total_amount), 0) as amt
      FROM invoices i
      JOIN expense_categories c ON i.category_id = c.id
      WHERE EXTRACT(YEAR FROM i.invoice_date) = SPLIT_PART(p_key, '-', 1)::INT
        AND CEIL(EXTRACT(MONTH FROM i.invoice_date) / 3.0) = SPLIT_PART(p_key, '-', 2)::INT
        AND i.status = 'approved'
      GROUP BY c.name
    ) sub;

  ELSIF p_type = 'annual' THEN
    SELECT COALESCE(SUM(total_amount), 0), COUNT(*)
    INTO v_total, v_count
    FROM invoices
    WHERE EXTRACT(YEAR FROM invoice_date) = p_key::INT
      AND status = 'approved';

    SELECT JSONB_OBJECT_AGG(c.name, sub.amt)
    INTO v_breakdown
    FROM (
      SELECT c.name, COALESCE(SUM(i.total_amount), 0) as amt
      FROM invoices i
      JOIN expense_categories c ON i.category_id = c.id
      WHERE EXTRACT(YEAR FROM i.invoice_date) = p_key::INT
        AND i.status = 'approved'
      GROUP BY c.name
    ) sub;
  END IF;

  -- Upsert report
  INSERT INTO expense_reports (report_type, period_key, total_amount, invoice_count, category_breakdown)
  VALUES (p_type, p_key, v_total, v_count, v_breakdown)
  ON CONFLICT (report_type, period_key)
  DO UPDATE SET
    total_amount = EXCLUDED.total_amount,
    invoice_count = EXCLUDED.invoice_count,
    category_breakdown = EXCLUDED.category_breakdown,
    generated_at = NOW();

  v_result := JSONB_BUILD_OBJECT(
    'type', p_type,
    'period', p_key,
    'total', v_total,
    'count', v_count,
    'breakdown', v_breakdown
  );

  RETURN v_result;
END;
$$;
