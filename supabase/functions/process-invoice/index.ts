// ECS 报销系统 - 发票识别 Edge Function
import { serve } from "https://deno.land/std@0.208.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

function corsHeaders() {
  return { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey", "Access-Control-Allow-Methods": "POST, OPTIONS" };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders() });

  try {
    const payload = await req.json();
    const record = payload.record || payload;
    if (!record || !record.storage_path) {
      return new Response(JSON.stringify({ error: "Invalid" }), { status: 400, headers: corsHeaders() });
    }

    const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    let invoiceId = record.id;

    if (!invoiceId) {
      const { data: found } = await supabase.from("invoices").select("id").eq("storage_path", record.storage_path).maybeSingle();
      if (found) invoiceId = found.id;
    }
    if (!invoiceId) return new Response(JSON.stringify({ success: false }), { status: 404, headers: corsHeaders() });

    // Download PDF
    const { data: fileData, error: dlErr } = await supabase.storage.from("invoices").download(record.storage_path);
    if (dlErr || !fileData) throw new Error("下载失败: " + (dlErr?.message || "空"));

    // Extract text
    const pdfBytes = await fileData.arrayBuffer();
    const rawText = await extractTextSmart(new Uint8Array(pdfBytes));

    if (!rawText || rawText.trim().length < 5 || rawText.includes("(cid:")) {
      await supabase.from("invoices").update({ raw_ocr_text: rawText?.substring(0, 500) || "[空]", status: "pending" }).eq("id", invoiceId);
      return new Response(JSON.stringify({ success: false, error: "无法提取文字" }), { headers: corsHeaders() });
    }

    // Parse and update
    const data = parseInvoiceText(rawText);
    const upd: Record<string, any> = { raw_ocr_text: rawText, ocr_confidence: 0.85 };
    for (const k of ["invoice_number", "invoice_date", "buyer_name", "seller_name", "item_description"]) {
      if ((data as any)[k]) upd[k] = (data as any)[k];
    }
    if (data.amount !== undefined) upd.amount = data.amount;
    if (data.total_amount !== undefined) upd.total_amount = data.total_amount;
    if (data.tax_amount !== undefined) upd.tax_amount = data.tax_amount;
    if (data.invoice_date) upd.expense_date = data.invoice_date;

    await supabase.from("invoices").update(upd).eq("id", invoiceId);
    await autoCategorize(supabase, invoiceId, data);
    if (data.invoice_date) await refreshReports(supabase, data.invoice_date);

    return new Response(JSON.stringify({ success: true, data }), { headers: { "Content-Type": "application/json", ...corsHeaders() } });
  } catch (e) {
    return new Response(JSON.stringify({ success: false, error: e.message }), { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders() } });
  }
});

// ============ PDF Text Extraction ============
async function extractTextSmart(data: Uint8Array): Promise<string> {
  const text = new TextDecoder("utf-8", { fatal: false }).decode(data);

  // Method 1: Extract text between parentheses from content streams
  const items: string[] = [];
  const btEtPattern = /BT([\s\S]*?)ET/g;
  let m;
  while ((m = btEtPattern.exec(text)) !== null) {
    const block = m[1];
    const strs: string[] = [];
    const p = /\(([^)]*)\)/g;
    let mm;
    while ((mm = p.exec(block)) !== null) {
      const s = mm[1];
      if (!/^cid:/i.test(s) && s.length >= 2) strs.push(s);
    }
    if (strs.length > 0) {
      const line = strs.join(" ");
      if (/[\u4e00-\u9fff]/.test(line) || /\d{6,}/.test(line) || /[¥￥]/.test(line)) items.push(line);
    }
  }

  // Method 2: Extract from TJ arrays
  if (items.length === 0) {
    const tjPat = /\[([^\]]*)\]\s*TJ/g;
    while ((m = tjPat.exec(text)) !== null) {
      const parts = m[1].match(/\(([^)]*)\)/g);
      if (parts) {
        const line = parts.map((p: string) => p.slice(1, -1)).join("");
        if (/[\u4e00-\u9fff]/.test(line) || /\d{10,}/.test(line)) items.push(line);
      }
    }
  }

  // Method 3: Extract from Tj operators outside BT/ET
  if (items.length === 0) {
    const tjPat = /\(([^)]{3,})\)\s*Tj/g;
    while ((m = tjPat.exec(text)) !== null) {
      const s = m[1];
      if (/[\u4e00-\u9fff]/.test(s) || /\d{8,}/.test(s)) items.push(s);
    }
  }

  // Check for CID encoding
  const allStrs: string[] = [];
  const strPat = /\(([^)]*)\)/g;
  while ((m = strPat.exec(text)) !== null) allStrs.push(m[1]);
  const cidCount = allStrs.filter(s => /^cid:\d+$/i.test(s)).length;

  if (cidCount > 5) {
    // Attempt CMap decoding
    const decoded = decodeWithCMap(text, allStrs);
    if (decoded && /[\u4e00-\u9fff]/.test(decoded)) return decoded;
    return "(cid:)";
  }

  return items.join("\n");
}

function decodeWithCMap(text: string, allStrs: string[]): string {
  // Extract CMap entries
  const map: Record<number, number> = {};

  // bfchar: <src> <dst>
  const bf = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g;
  let m;
  while ((m = bf.exec(text)) !== null) {
    const src = parseInt(m[1], 16);
    const dst = parseInt(m[2], 16);
    if (dst > 0x20) map[src] = dst;
  }

  // bfrange: <srcStart> <srcEnd> <dstStart>
  const bfr = /<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/g;
  while ((m = bfr.exec(text)) !== null) {
    const s = parseInt(m[1], 16), e = parseInt(m[2], 16), d = parseInt(m[3], 16);
    for (let i = 0; i <= e - s; i++) map[s + i] = d + i;
  }

  if (Object.keys(map).length === 0) return "";

  return allStrs.map(s => {
    const cid = parseInt(s.replace(/^cid:/i, ""), 10);
    const cp = map[cid];
    return cp ? String.fromCodePoint(cp) : "";
  }).join("");
}

// ============ Invoice Parsing ============
function parseInvoiceText(text: string): any {
  const data: any = {};
  const t = text.replace(/\u200b/g, "").replace(/\s+/g, " ").trim();
  const m1 = t.match(/发票[号码码簿]\s*[：:]\s*(\d{8,25})/);
  if (m1) data.invoice_number = m1[1];
  const m2 = t.match(/(?:开票日期|开票⽇期)\s*[：:]\s*(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日/);
  if (m2) data.invoice_date = `${m2[1]}-${m2[2].padStart(2,"0")}-${m2[3].padStart(2,"0")}`;

  if (t.includes("铁路")) {
    data.item_description = "铁路交通费";
    const st = [...t.matchAll(/([\u4e00-\u9fff]{2,6}站)/g)].map((x: any) => x[1]);
    if (st.length >= 2) data.item_description = `${st[0]}→${st[st.length-1]} 高铁`;
    const pr = t.match(/票价\s*[：:]\s*¥?\s*(\d+\.?\d*)/);
    if (pr) data.total_amount = parseFloat(pr[1]);
    return data;
  }

  const bs = section(t, "购买方", "销售方");
  if (bs) { const n = bs.match(/(?:名称|名[称称])\s*[：:]\s*(.+?)(?:\s|$)/); if (n) data.buyer_name = n[1].trim(); }
  const ss = section(t, "销售方", "项目名称|开票人|备注");
  if (ss) { const n = ss.match(/(?:名称|名[称称])\s*[：:]\s*(.+?)(?:\s|$)/); if (n) data.seller_name = n[1].trim(); }
  const im = t.match(/项目名称\s*\*?([^*]*\*[^*]*\*)?\s*([^\s]+)/);
  if (im) data.item_description = (im[2] || im[1] || "").trim();
  const am = t.match(/金[额额]\s*[：:]\s*¥?\s*(\d+\.?\d*)/);
  if (am) data.amount = parseFloat(am[1]);
  const tx = t.match(/税[额额]\s*[：:]\s*¥?\s*(\d+\.?\d*)/);
  if (tx) data.tax_amount = parseFloat(tx[1]);
  const tl = t.match(/价税合计[^]*?小写[^)]*\）[^]*?¥?\s*(\d+\.?\d*)/);
  if (tl) data.total_amount = parseFloat(tl[1]);

  return data;
}

function section(t: string, s: string, e: string): string {
  const i = t.indexOf(s); if (i === -1) return "";
  const r = t.slice(i + s.length); const m = r.match(new RegExp(`(${e})`));
  return r.slice(0, m ? m.index! : r.length);
}

async function autoCategorize(supabase: any, id: number, data: any) {
  const s = (data.seller_name || "").toLowerCase();
  const i = (data.item_description || "").toLowerCase();
  let cat = "";
  if (i.includes("铁路") || i.includes("高铁") || i.includes("→") || s.includes("航空")) cat = "出差交通费";
  else if (s.includes("餐饮") || s.includes("餐厅")) cat = i.includes("客情") ? "客情餐饮费" : "出差餐饮费";
  else if (s.includes("酒店") || s.includes("宾馆")) cat = "出差住房费";
  else if (s.includes("石油") || s.includes("石化") || s.includes("加油站") || i.includes("油")) cat = "出差交通费";
  if (cat) {
    const { data: c } = await supabase.from("expense_categories").select("id").eq("name", cat).single();
    if (c) await supabase.from("invoices").update({ category_id: c.id }).eq("id", id);
  }
}

async function refreshReports(supabase: any, ds: string) {
  const d = new Date(ds);
  const y = d.getFullYear(), m = String(d.getMonth()+1).padStart(2,"0"), q = Math.ceil((d.getMonth()+1)/3);
  for (const [t, k] of [["monthly",`${y}-${m}`],["quarterly",`${y}-Q${q}`],["annual",String(y)]] as const)
    await supabase.rpc("refresh_expense_report", { p_type: t, p_key: k }).catch(() => {});
}
