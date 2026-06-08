// ============================================================
// ECS 报销管理系统 - OCR发票识别 Edge Function
// Supabase Edge Function (Deno)
// 触发方式: 上传PDF到Storage后自动触发 或 手动调用
// ============================================================

import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

// Tesseract.js for OCR
import { createWorker } from "https://esm.sh/tesseract.js@5.0.4";

interface InvoiceData {
  invoice_number?: string;
  invoice_date?: string;
  buyer_name?: string;
  buyer_tax_id?: string;
  seller_name?: string;
  seller_tax_id?: string;
  item_description?: string;
  amount?: number;
  tax_amount?: number;
  total_amount?: number;
}

serve(async (req) => {
  try {
    // Parse request
    const { record, event } = await req.json();
    
    if (event !== "INSERT" || !record) {
      return new Response(JSON.stringify({ error: "Invalid event" }), { status: 400 });
    }

    const storagePath = record.storage_path;
    if (!storagePath) {
      return new Response(JSON.stringify({ error: "No storage path" }), { status: 400 });
    }

    // Initialize Supabase client
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, supabaseKey);

    // Download PDF from Storage
    const { data: fileData, error: downloadError } = await supabase.storage
      .from("invoices")
      .download(storagePath);

    if (downloadError || !fileData) {
      throw new Error(`Download failed: ${downloadError?.message || "No data"}`);
    }

    // Convert PDF to image buffer for OCR
    // Using pdf.js to render PDF to images
    const pdfBytes = await fileData.arrayBuffer();
    
    // Initialize Tesseract.js worker
    const worker = await createWorker("chi_sim+eng");
    
    // OCR processing
    const ocrResult = await worker.recognize(pdfBytes);
    const rawText = ocrResult.data.text;
    
    // Extract invoice data from OCR text
    const invoiceData = extractInvoiceData(rawText);
    
    // Update the invoice record
    const updateData: Record<string, any> = {
      raw_ocr_text: rawText,
      ocr_confidence: ocrResult.data.confidence / 100,
    };

    if (invoiceData.invoice_number) updateData.invoice_number = invoiceData.invoice_number;
    if (invoiceData.invoice_date) updateData.invoice_date = invoiceData.invoice_date;
    if (invoiceData.buyer_name) updateData.buyer_name = invoiceData.buyer_name;
    if (invoiceData.buyer_tax_id) updateData.buyer_tax_id = invoiceData.buyer_tax_id;
    if (invoiceData.seller_name) updateData.seller_name = invoiceData.seller_name;
    if (invoiceData.seller_tax_id) updateData.seller_tax_id = invoiceData.seller_tax_id;
    if (invoiceData.item_description) updateData.item_description = invoiceData.item_description;
    if (invoiceData.amount !== undefined) updateData.amount = invoiceData.amount;
    if (invoiceData.tax_amount !== undefined) updateData.tax_amount = invoiceData.tax_amount;
    if (invoiceData.total_amount !== undefined) updateData.total_amount = invoiceData.total_amount;

    const { error: updateError } = await supabase
      .from("invoices")
      .update(updateData)
      .eq("id", record.id);

    if (updateError) {
      throw new Error(`Update failed: ${updateError.message}`);
    }

    // Auto-categorize based on seller/item
    await autoCategorize(supabase, record.id, invoiceData);

    // Auto-refresh reports
    if (invoiceData.invoice_date) {
      const date = new Date(invoiceData.invoice_date);
      const year = date.getFullYear();
      const month = String(date.getMonth() + 1).padStart(2, "0");
      const quarter = Math.ceil((date.getMonth() + 1) / 3);

      // Refresh monthly report
      await supabase.rpc("refresh_expense_report", {
        p_type: "monthly",
        p_key: `${year}-${month}`,
      });

      // Refresh quarterly report
      await supabase.rpc("refresh_expense_report", {
        p_type: "quarterly",
        p_key: `${year}-Q${quarter}`,
      });

      // Refresh annual report
      await supabase.rpc("refresh_expense_report", {
        p_type: "annual",
        p_key: String(year),
      });
    }

    await worker.terminate();

    return new Response(
      JSON.stringify({ success: true, data: invoiceData }),
      { headers: { "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("OCR processing error:", error);
    return new Response(
      JSON.stringify({ success: false, error: error.message }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});

// ============================================================
// 发票数据提取逻辑
// ============================================================
function extractInvoiceData(text: string): InvoiceData {
  const data: InvoiceData = {};
  const lines = text.split("\n").map(l => l.trim()).filter(Boolean);

  // 发票号码
  const invNoMatch = text.match(/发票号码[：:]\s*(\S+)/);
  if (invNoMatch) data.invoice_number = invNoMatch[1];

  // 开票日期
  const dateMatch = text.match(/(?:开票日期|开票⽇期)[：:]\s*(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日/);
  if (dateMatch) {
    const [_, y, m, d] = dateMatch;
    data.invoice_date = `${y}-${m.padStart(2, "0")}-${d.padStart(2, "0")}`;
  }

  // 购买方
  const buyerMatch = text.match(/(?:购买方|购\u200b买\u200b方)[^]*?名称[：:]\s*(.+?)(?:\n|$)/);
  if (buyerMatch) data.buyer_name = buyerMatch[1].trim();
  
  const buyerTaxMatch = text.match(/(?:购买方|购\u200b买\u200b方)[^]*?(?:统一社会信用代码|纳税人识别号)[：:]\s*(\S+)/);
  if (buyerTaxMatch) data.buyer_tax_id = buyerTaxMatch[1].trim();

  // 销售方
  const sellerMatch = text.match(/(?:销售方|销\u200b售\u200b方)[^]*?名称[：:]\s*(.+?)(?:\n|$)/);
  if (sellerMatch) data.seller_name = sellerMatch[1].trim();
  
  const sellerTaxMatch = text.match(/(?:销售方|销\u200b售\u200b方)[^]*?(?:统一社会信用代码|纳税人识别号)[：:]\s*(\S+)/);
  if (sellerTaxMatch) data.seller_tax_id = sellerTaxMatch[1].trim();

  // 金额
  const amountMatch = text.match(/金额[：:]*\s*¥?\s*(\d+\.?\d*)/);
  if (amountMatch) data.amount = parseFloat(amountMatch[1]);

  const totalMatch = text.match(/(?:价税合计|小计)[^]*?[（(]小写[）)][^]*?¥?\s*(\d+\.?\d*)/);
  if (totalMatch) {
    data.total_amount = parseFloat(totalMatch[1]);
  } else {
    const totalMatch2 = text.match(/¥\s*(\d+\.?\d*)\s*$/m);
    if (totalMatch2) data.total_amount = parseFloat(totalMatch2[1]);
  }

  const taxMatch = text.match(/税额[：:]*\s*¥?\s*(\d+\.?\d*)/);
  if (taxMatch) data.tax_amount = parseFloat(taxMatch[1]);

  // 项目名称
  const itemMatch = text.match(/项目名称[^]*?(?:\*[^*]+\*)\s*([^\n]+)/);
  if (itemMatch) data.item_description = itemMatch[1].trim();
  
  // 铁路电子客票特殊处理
  if (text.includes("铁路电子客票") || text.includes("铁路电⼦客票")) {
    data.item_description = "铁路交通费";
    
    const fromMatch = text.match(/(\S+站)\s*\n/);
    const toMatch = text.match(/C?\d+\s*\n\s*(\S+站)/);
    if (fromMatch && toMatch) {
      data.item_description = `${fromMatch[1]}→${toMatch[1]} 高铁`;
    }
  }

  return data;
}

// ============================================================
// 自动归类
// ============================================================
async function autoCategorize(supabase: any, invoiceId: number, data: InvoiceData) {
  const sellerName = (data.seller_name || "").toLowerCase();
  const itemDesc = (data.item_description || "").toLowerCase();

  let categoryName = "日常餐饮费"; // default

  // Simple rule-based categorization
  if (sellerName.includes("餐饮") || sellerName.includes("餐厅") || sellerName.includes("酒店")) {
    // Check if it mentions client/客情 keywords
    if (itemDesc.includes("客情") || itemDesc.includes("客户")) {
      categoryName = "客情餐饮费";
    } else if (sellerName.includes("酒店") || sellerName.includes("宾馆")) {
      categoryName = "出差住房费";
    } else {
      categoryName = "出差餐饮费";
    }
  } else if (sellerName.includes("石油") || sellerName.includes("石化") || sellerName.includes("加油站") || itemDesc.includes("油费")) {
    categoryName = "出差交通费";
  } else if (itemDesc.includes("铁路") || itemDesc.includes("高铁") || itemDesc.includes("机票") || sellerName.includes("航空")) {
    categoryName = "出差交通费";
  } else if (sellerName.includes("通讯") || sellerName.includes("移动") || sellerName.includes("电信") || sellerName.includes("联通")) {
    categoryName = "通讯费";
  } else if (sellerName.includes("办公") || sellerName.includes("文具") || sellerName.includes("科技")) {
    categoryName = "办公用品";
  }

  // Get category ID
  const { data: cat } = await supabase
    .from("expense_categories")
    .select("id")
    .eq("name", categoryName)
    .single();

  if (cat) {
    await supabase
      .from("invoices")
      .update({ category_id: cat.id })
      .eq("id", invoiceId);
  }
}
