-- ECS 报销管理系统 - 数据库初始化
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- 用户表
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  name TEXT DEFAULT '',
  password_hash TEXT NOT NULL,
  role TEXT DEFAULT 'member' CHECK(role IN ('member','admin','super_admin')),
  status TEXT DEFAULT 'active' CHECK(status IN ('active','inactive')),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 费用类别表
CREATE TABLE IF NOT EXISTS expense_categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  description TEXT DEFAULT '',
  sort_order INTEGER DEFAULT 99,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 发票表
CREATE TABLE IF NOT EXISTS invoices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  storage_path TEXT NOT NULL,
  original_filename TEXT NOT NULL,
  file_size INTEGER DEFAULT 0,
  invoice_number TEXT DEFAULT '',
  invoice_date TEXT DEFAULT '',
  seller_name TEXT DEFAULT '',
  buyer_name TEXT DEFAULT '',
  amount REAL DEFAULT 0,
  tax_amount REAL DEFAULT 0,
  total_amount REAL DEFAULT 0,
  category_id INTEGER DEFAULT NULL,
  project_location TEXT DEFAULT '',
  expense_note TEXT DEFAULT '',
  item_description TEXT DEFAULT '',
  raw_ocr_text TEXT DEFAULT '',
  status TEXT DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected')),
  uploaded_by TEXT NOT NULL,
  reviewed_by TEXT DEFAULT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (category_id) REFERENCES expense_categories(id),
  FOREIGN KEY (uploaded_by) REFERENCES users(id)
);

-- 默认分类数据（与 Supabase 版本完全一致）
INSERT OR IGNORE INTO expense_categories (id, name, description, sort_order) VALUES
  (1, '办公用品', '办公用品采购', 1),
  (2, '出差餐饮费', '出差期间的餐饮支出', 2),
  (3, '出差交通费', '出差交通支出（机票、高铁、打车等）', 3),
  (4, '出差住房费', '出差住宿支出', 4),
  (5, '客情餐饮费', '客户/客情关系维护餐饮支出', 5),
  (6, '日常餐饮费', '日常团队餐饮支出', 6),
  (7, '通讯费', '手机话费等通讯支出', 7),
  (8, '外出交通费', '本地外出交通支出（打车、地铁等）', 8);
