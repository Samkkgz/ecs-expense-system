-- ============================================================
-- ECS v4.19.4 - 修复 refresh_expense_report 函数 SQL 错误
-- ============================================================
-- 根因：三处 JSONB_OBJECT_AGG(c.name, sub.amt) 引用了子查询外部
-- 不存在的表别名 c（子查询别名是 sub），函数一调用即报
-- "missing FROM-clause entry for table c"，报表缓存永不刷新。
-- 修复：改为引用子查询别名 JSONB_OBJECT_AGG(sub.name, sub.amt)。
-- 脚本幂等，可重复执行（CREATE OR REPLACE）。

CREATE OR REPLACE FUNCTION public.refresh_expense_report(p_type text, p_key text, p_company_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    SELECT JSONB_OBJECT_AGG(sub.name, sub.amt) INTO v_breakdown
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
    SELECT JSONB_OBJECT_AGG(sub.name, sub.amt) INTO v_breakdown
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
    SELECT JSONB_OBJECT_AGG(sub.name, sub.amt) INTO v_breakdown
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
$function$;
