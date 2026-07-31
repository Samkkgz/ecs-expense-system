-- v4.17.0 一次性数据修正（2026-07-31）
-- 将 sam.lu@bsctradingltd.top 及其名下发票归属迁移到「逸创网络」(company_id=1)
-- 注意：这是用户明确要求的一次性迁移；管理员面板后续修改公司不会自动迁移历史发票。

BEGIN;

INSERT INTO public.user_companies (user_id, company_id)
SELECT id, 1 FROM public.profiles WHERE email = 'sam.lu@bsctradingltd.top'
ON CONFLICT (user_id, company_id) DO NOTHING;

DELETE FROM public.user_companies
WHERE user_id = (SELECT id FROM public.profiles WHERE email = 'sam.lu@bsctradingltd.top')
  AND company_id <> 1;

UPDATE public.invoices
SET company_id = 1, updated_at = NOW()
WHERE uploaded_by = (SELECT id FROM public.profiles WHERE email = 'sam.lu@bsctradingltd.top')
  AND company_id IS DISTINCT FROM 1;

COMMIT;
