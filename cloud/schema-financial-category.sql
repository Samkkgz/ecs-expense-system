-- ============================================================
-- ECS 报销管理系统 - 财务类目迁移脚本（v4.6+）
-- 在 Supabase 管理面板的 SQL Editor 中执行
-- 添加 financial_category 字段并初始化已有类目
-- ============================================================

-- 1. 添加 financial_category 列（幂等）
ALTER TABLE expense_categories ADD COLUMN IF NOT EXISTS financial_category TEXT;

-- 2. 根据映射关系填充已有类目的财务类目
UPDATE expense_categories SET financial_category = '办公费' WHERE name = '办公用品' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '差旅费' WHERE name = '出差交通费' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '差旅费' WHERE name = '出差餐饮费' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '差旅费' WHERE name = '出差住房费' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '招待费' WHERE name = '客情餐饮费' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '福利费' WHERE name = '日常餐饮费' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '通讯费' WHERE name = '通讯费' AND (financial_category IS NULL OR financial_category = '');
UPDATE expense_categories SET financial_category = '差旅费' WHERE name = '外出交通费' AND (financial_category IS NULL OR financial_category = '');

-- 3. 添加"商务应酬"类目（如尚不存在）
INSERT INTO expense_categories (name, financial_category, description, sort_order)
SELECT '商务应酬', '招待费', '商务招待及应酬支出', 9
WHERE NOT EXISTS (SELECT 1 FROM expense_categories WHERE name = '商务应酬');

-- 验证
SELECT id, name, financial_category, description FROM expense_categories ORDER BY sort_order;
