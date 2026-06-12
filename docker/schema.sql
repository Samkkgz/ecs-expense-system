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

-- 默认分类数据
INSERT OR IGNORE INTO expense_categories (id, name, description, sort_order) VALUES
  (1, '交通费', '出租车、地铁、公交等', 1),
  (2, '餐费', '餐饮、工作餐等', 2),
  (3, '住宿费', '酒店住宿', 3),
  (4, '办公用品', '文具、耗材等', 4),
  (5, '通讯费', '电话费、网络费等', 5),
  (6, '差旅费', '出差相关综合费用', 6),
  (7, '油费', '车辆加油费用', 7),
  (8, '停车费', '停车费用', 8),
  (9, '其他', '其他费用', 99);
