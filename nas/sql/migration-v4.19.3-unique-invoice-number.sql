-- ============================================================
-- ECS v4.19.3 - 发票号级唯一索引（防重复上传最终兜底）
-- ============================================================
-- 背景：同一张发票可能以不同文件名/大小多次入库（照片 vs PDF），
-- 旧逻辑（original_filename + file_size）无法拦截。
-- 本索引确保 invoice_number 非空时全局唯一，任何路径（前端/API/脚本）
-- 都无法再插入同号发票。
--
-- 前置条件：必须先清理已存在的同号重复记录，否则建索引会失败。
-- 脚本幂等，可重复执行。

DROP INDEX IF EXISTS uq_invoices_invoice_number;

CREATE UNIQUE INDEX uq_invoices_invoice_number
  ON public.invoices (invoice_number)
  WHERE invoice_number IS NOT NULL AND btrim(invoice_number) <> '';
