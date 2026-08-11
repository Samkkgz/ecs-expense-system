#!/usr/bin/env python3
"""ECS v4.11 - OCR 识别服务
架构: 前端渲染PDF→图片 → OCR处理Baidu → OCR直接保存DB(通过gateway:8000 + SERVICE_KEY)
双重保障: OCR通过REST API保存DB + 前端通过Supabase SDK保存DB
对比v4.10修复:
  1. image_base64路径: 恢复直接保存DB(v4.8方案)
  2. storage_path路径: PDF立即返回need_image, 图片用gateway:8000+SERVICE_KEY下载
  3. 下载URL: 从 LAN IP(192.168.3.150) 改回 gateway:8000(Docker内部网络) + 认证头
"""
import os, json, re, base64, io, sys
import urllib.request, urllib.error, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", 9000))
BAIDU_API_KEY = os.environ.get("BAIDU_API_KEY", "")
BAIDU_SECRET_KEY = os.environ.get("BAIDU_SECRET_KEY", "")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "http://gateway:8000")
SERVICE_KEY = os.environ.get("SERVICE_KEY", "")

CHINA_CITIES = ["广州","深圳","珠海","汕头","佛山","韶关","湛江","肇庆","江门","茂名","惠州",
    "梅州","汕尾","河源","阳江","清远","东莞","中山","潮州","揭阳","云浮","北京","上海","天津",
    "重庆","南京","苏州","无锡","常州","镇江","扬州","南通","徐州","杭州","宁波","温州","嘉兴",
    "绍兴","金华","成都","武汉","长沙","西安","郑州","济南","青岛","大连","沈阳","厦门","福州",
    "合肥","昆明","贵阳","南宁","海口","三亚","拉萨","兰州","西宁","银川","乌鲁木齐","呼和浩特",
    "石家庄","太原","哈尔滨","长春","南昌","香港","澳门","台北","曼谷","新加坡"]

def http_json(method, url, body=None, headers=None, timeout=30):
    """stdlib HTTP, returns (status, data_or_error)"""
    req_headers = headers or {}
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        req_headers["Content-Type"] = "application/json"
    try:
        req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")[:500]
        print(f"[HTTP] {method} {url} -> {e.code} {err_body}", flush=True)
        return e.code, f"{e.code} {err_body}"
    except Exception as e:
        print(f"[HTTP] {method} {url} -> {e}", flush=True)
        return 0, str(e)

def detect_city(text):
    if not text: return None
    for city in CHINA_CITIES:
        if city in str(text): return city
    return None

def baidu_access_token():
    if not BAIDU_API_KEY or not BAIDU_SECRET_KEY:
        print("[Baidu] Missing API credentials", flush=True)
        return None
    params = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": BAIDU_API_KEY,
        "client_secret": BAIDU_SECRET_KEY
    })
    url = f"https://aip.baidubce.com/oauth/2.0/token?{params}"
    status, result = http_json("GET", url, timeout=10)
    if status == 200 and isinstance(result, dict):
        token = result.get("access_token")
        if token: return token
    print(f"[Baidu] token failed: {result}", flush=True)
    return None

def call_baidu_ocr(image_base64, ocr_type="vat_invoice"):
    token = baidu_access_token()
    if not token: return None, "百度Token获取失败"
    url = f"https://aip.baidubce.com/rest/2.0/ocr/v1/{ocr_type}?access_token={token}"
    data = urllib.parse.urlencode({"image": image_base64}).encode()
    try:
        req = urllib.request.Request(url, data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
        if "error_code" in result:
            return None, f"百度API错误 {result.get('error_code')}: {result.get('error_msg', '未知')}"
        print(f"[OCR] Baidu response keys: {list(result.keys())}", flush=True)
        return result, None
    except Exception as e:
        return None, str(e)

def parse_ocr_result(ocr_data):
    """Parse Baidu OCR result - supports structured VAT invoice + regex fallback"""
    result = {}
    if not ocr_data: return result

    raw = ocr_data.get("words_result", ocr_data)
    if isinstance(raw, dict):
        raw_dict = raw
        text_blob = flatten_words(raw_dict)
    elif isinstance(raw, list):
        raw_dict = {}
        text_blob = " ".join(w.get("words","") for w in raw) if raw else ""
    else:
        raw_dict = {}
        text_blob = ""
    text_blob = re.sub(r"\s+", "", text_blob)
    print(f"[OCR] parse: raw_dict keys={list(raw_dict.keys())[:20]}", flush=True)

    # Structured field extraction
    for f in ["InvoiceNum", "InvoiceNumDigit", "InvoiceCode", "InvoiceNumConfirm"]:
        v = raw_dict.get(f, "")
        if isinstance(v, dict): v = v.get("word", str(v))
        if v and re.search(r"\d{8}", str(v)):
            result["invoice_number"] = str(v).strip(); break

    date_str = str(raw_dict.get("InvoiceDate", ""))
    m = re.search(r"(\d{4})[年\-./\s](\d{1,2})[月\-./\s](\d{1,2})", date_str)
    if m and 2020 <= int(m.group(1)) <= 2030:
        result["invoice_date"] = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"

    for f in ["AmountInFiguers", "TotalAmount"]:
        v = str(raw_dict.get(f, "")).replace(",", "").replace("，", "")
        try:
            nums = re.findall(r"(\d+\.?\d*)", v)
            if nums:
                amt = float(nums[0])
                if amt > 0: result["total_amount"] = amt; break
        except: pass

    if "total_amount" not in result:
        ca = raw_dict.get("CommodityAmount", [])
        if isinstance(ca, list):
            total = 0
            for item in ca:
                try:
                    total += float(str(item.get("word", item.get("words", "0"))).replace(",",""))
                except: pass
            if total > 0: result["total_amount"] = total

    for f in ["SellerName", "Seller"]:
        v = raw_dict.get(f, "")
        if isinstance(v, dict): v = v.get("word", str(v))
        v = str(v).strip()
        if v and len(v) >= 2 and not v.startswith("*"):
            result["seller_name"] = v; break

    for f in ["SellerAddress", "PurchaserAddress", "SellerBank"]:
        city = detect_city(str(raw_dict.get(f, "")))
        if city: result["project_location"] = city; break

    # Regex fallbacks
    if not result.get("invoice_number"):
        m = re.search(r"(?:发票号码|发票号|号码|票号|No[\.\s]*)[：:]*\s*(\d{8,20})", text_blob)
        if m: result["invoice_number"] = m.group(1)
    if not result.get("invoice_number"):
        m = re.search(r"\b(\d{8})\b", text_blob)
        if m: result["invoice_number"] = m.group(1)

    if not result.get("invoice_date"):
        m = re.search(r"(\d{4})[年\-](\d{1,2})[月\-](\d{1,2})", text_blob)
        if m and 2020 <= int(m.group(1)) <= 2030:
            result["invoice_date"] = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"

    if not result.get("total_amount"):
        patterns = [
            r"价税合计[^\d]*[¥￥]?\s*(\d+\.\d{2})",
            r"合计[^\d]*[¥￥]?\s*(\d+\.\d{2})",
            r"[¥￥]\s*(\d+\.\d{2})",
            r"小写[：:]\s*[¥￥]?\s*(\d+\.\d{2})",
            r"金额[：:]\s*[¥￥]?\s*(\d+\.\d{2})",
        ]
        for p in patterns:
            m = re.search(p, text_blob)
            if m: result["total_amount"] = float(m.group(1)); break
        if "total_amount" not in result:
            nums = re.findall(r"(\d+\.\d{2})", text_blob)
            if nums: result["total_amount"] = float(max(nums, key=float))

    if not result.get("seller_name"):
        for prefix in ["销售方名", "销售方", "收款方", "商户名称", "销货方"]:
            idx = text_blob.find(prefix)
            if idx >= 0:
                chunk = text_blob[idx:idx+60]
                m = re.search(r"[：:]\s*([^\s\n]{2,30})", chunk)
                if m: result["seller_name"] = m.group(1).strip(); break
                m = re.search(r"称\s*[：:]*\s*([^\s\n]{2,30})", chunk)
                if m: result["seller_name"] = m.group(1).strip(); break

    if not result.get("project_location"):
        city = detect_city(text_blob)
        if city: result["project_location"] = city

    print(f"[OCR] parse result: {json.dumps(result, ensure_ascii=False)}", flush=True)
    return result

def flatten_words(raw_dict):
    parts = []
    for v in raw_dict.values():
        if isinstance(v, list):
            for item in v:
                if isinstance(item, dict):
                    parts.append(item.get("word", item.get("words", "")))
                elif isinstance(item, str):
                    parts.append(item)
        elif isinstance(v, dict):
            parts.append(v.get("words", v.get("word", "")))
        elif isinstance(v, str):
            parts.append(v)
    return " ".join(p for p in parts if p)

CATEGORY_KEYWORDS = {}
MERCHANT_KW = {
    "办公用品": ["文具","办公","打印","复印","耗材","墨盒","硒鼓","纸张","纸业","文件夹","得力","晨光","齐心","惠普","佳能"],
    "出差交通费": ["航空","机票","火车","高铁","加油","石油","石化","航司","东方航空","南方航空","国航","海航"],
    "出差住房费": ["酒店","宾馆","民宿","旅馆","客栈","公寓","招待所","度假","如家","锦江","汉庭","全季","维也纳","希尔顿","万豪","洲际","华住"],
    "通讯费": ["电信","移动","联通","通讯","通信","话费","流量","宽带","中国电信","中国移动","中国联通"],
    "外出交通费": ["滴滴","出租","停车","公交","地铁","充电","高德","曹操","T3","首汽","嘀嗒","顺丰","中通","圆通","韵达"],
}
FOOD_KW = ["餐厅","饭店","酒楼","酒家","快餐","小吃","奶茶","咖啡","食堂","食府","火锅","烧烤","料理","面馆","米粉","包子","馒头","饺子","烘焙","蛋糕","甜品","饮吧","餐","鸡","鸭","鱼","虾","蟹","海鲜","牛排","披萨","汉堡","麦当劳","肯德基","必胜客","海底捞","西贝","太二","探鱼","点都德","陶陶居","广州酒家","炳胜"]

def load_categories_from_db():
    global CATEGORY_KEYWORDS
    ok, cats = supabase_api("expense_categories?select=id,name,description", "GET")
    if not ok or not isinstance(cats, list):
        print(f"[OCR] Failed to load categories: {cats}", flush=True)
        CATEGORY_KEYWORDS = {}
        return
    for c in cats:
        name = c.get("name", "")
        cid = c.get("id")
        kws = set()
        for text_val in [name, c.get("description", "")]:
            t = text_val.replace("费","").replace("支出","")
            for i in range(len(t)):
                for j in (2,3):
                    if i+j <= len(t): kws.add(t[i:i+j])
        if "餐饮" in name:
            kws.update(FOOD_KW)
        if name in MERCHANT_KW:
            kws.update(MERCHANT_KW[name])
        CATEGORY_KEYWORDS[name] = {"id": cid, "keywords": kws}
    print(f"[OCR] Loaded {len(CATEGORY_KEYWORDS)} categories", flush=True)

def auto_categorize(seller_name, item_desc):
    if not CATEGORY_KEYWORDS: return None
    s = (seller_name or "").lower()
    d = (item_desc or "").lower()
    combined = s + " " + d
    best_match = None
    best_score = 0
    for cat_name, info in CATEGORY_KEYWORDS.items():
        score = 0
        for kw in info["keywords"]:
            if kw in combined: score += len(kw)
        if score > best_score:
            best_score = score
            best_match = cat_name
    return best_match

def supabase_api(path, method="GET", body=None):
    """Call PostgREST directly via Docker internal network with service_role key"""
    url = f"http://rest:3000/{path}"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json"
    }
    if method == "PATCH":
        headers["Prefer"] = "return=representation"
    status, result = http_json(method, url, body=body, headers=headers, timeout=15)
    if status in (200, 201):
        return True, result
    return False, str(result)


def find_duplicate_invoice(parsed, invoice_id):
    """v4.19.3 发票号级去重：按发票号码查找同号的其他记录（排除自身）。
    Returns: 已存在的记录 dict 或 None
    """
    num = (parsed.get("invoice_number") or "").strip()
    if not num:
        return None
    q = f"invoices?select=id,storage_path&invoice_number=eq.{urllib.parse.quote(num)}&id=neq.{invoice_id}&limit=1"
    ok, rows = supabase_api(q, "GET")
    if ok and isinstance(rows, list) and rows:
        return rows[0]
    return None


def delete_invoice_with_storage(invoice_id, storage_path):
    """删除数据库记录，并尽力清理对应的 Storage 文件（失败不阻塞）。"""
    try:
        supabase_api(f"invoices?id=eq.{invoice_id}", "DELETE")
    except Exception:
        pass
    if storage_path:
        try:
            url = f"http://storage:5000/object/invoices/{storage_path}"
            headers = {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}
            req = urllib.request.Request(url, headers=headers, method="DELETE")
            with urllib.request.urlopen(req, timeout=15):
                pass
        except Exception:
            pass


def merge_duplicate_invoice(invoice_id, storage_path, existing, updates):
    """发票重复时：删除当前记录，把 OCR 数据合并到已存在的旧记录。"""
    delete_invoice_with_storage(invoice_id, storage_path)
    supabase_api(f"invoices?id=eq.{existing['id']}", "PATCH", updates)
    return existing


class OCRHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, apikey")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.end_headers()

    def do_POST(self):
        if self.path in ("/", "/functions/v1/"):
            self._json(200, {"status": "ok", "deps": "stdlib"})
            return
        if self.path not in ("/process-invoice", "/functions/v1/process-invoice", "/ocr"):
            self._json(404, {"error": f"Not found: {self.path}"})
            return

        try:
            cl = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(cl)) if cl > 0 else {}
        except Exception:
            self._json(400, {"error": "Invalid JSON body"})
            return

        record = body.get("record") or body
        storage_path = record.get("storage_path", "")
        invoice_id = record.get("id")
        image_base64 = record.get("image_base64")

        if storage_path.startswith("invoices/"):
            storage_path = storage_path[9:]

        if not invoice_id:
            self._json(400, {"error": "missing invoice id"})
            return

        print(f"[OCR] Request: id={invoice_id} path={storage_path} has_image={'YES' if image_base64 else 'NO'}", flush=True)

        # === PATH A: Image-based OCR (main flow) ===
        # Frontend renders PDF to image, sends image_base64.
        # OCR processes image via Baidu and saves results directly to DB.
        # Dual-redundancy: OCR saves via REST API (this path) + frontend also saves via Supabase SDK.
        if image_base64:
            ocr_data, err = call_baidu_ocr(image_base64, "vat_invoice")
            if err:
                print(f"[OCR] vat_invoice failed: {err}, trying general", flush=True)
                ocr_data, err = call_baidu_ocr(image_base64, "general")

            if ocr_data and not err:
                parsed = parse_ocr_result(ocr_data)
                print(f"[OCR] parsed: {json.dumps(parsed, ensure_ascii=False)}", flush=True)

                # Save to DB directly via REST API (Docker internal network)
                # v4.16: 识别只保存字段，不改变审批状态（保持草稿，由用户确认后提交）
                updates = {}
                for k in ["invoice_number","invoice_date","seller_name","total_amount","project_location","raw_ocr_text"]:
                    v = parsed.get(k)
                    if v: updates[k] = v
                updates["raw_ocr_text"] = str(ocr_data)[:500]
                if parsed.get("project_location"):
                    updates["project_location"] = parsed["project_location"]

                # v4.19.3 发票号级去重：同号已存在时合并到旧记录并删除当前
                dup = find_duplicate_invoice(parsed, invoice_id)
                if dup:
                    merge_duplicate_invoice(invoice_id, storage_path, dup, updates)
                    print(f"[OCR] 检测到重复发票号 {parsed.get('invoice_number')}，已合并到 ID {dup['id']} 并删除 ID {invoice_id}", flush=True)
                    self._json(200, {"success": True, "data": {**parsed, "id": dup["id"], "merged": True}, "raw": str(ocr_data)[:500], "merged": True, "merged_id": dup["id"], "db_save": True})
                    return

                ok, api_result = supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                if not ok:
                    print(f"[OCR] DB save failed: {api_result}", flush=True)
                    # Return data to frontend as fallback
                    self._json(200, {"success": True, "data": parsed, "raw": str(ocr_data)[:500], "db_save": False})
                    return
                print(f"[OCR] DB saved OK, id={invoice_id}", flush=True)
                self._json(200, {"success": True, "data": parsed, "raw": str(ocr_data)[:500], "db_save": True})
                return
            else:
                self._json(200, {"success": False, "error": f"OCR failed: {err}"})
                return

        # === PATH B: Storage path only (no image) ===
        # For PDFs: return need_image so frontend renders to image
        # For images (PNG/JPG): download and process directly
        if storage_path and not image_base64:
            ext = os.path.splitext(storage_path)[1].lower()
            if ext == ".pdf":
                self._json(200, {"success": False, "need_image": True, "error": "PDF需要前端渲染为图片"})
                return
            # Image file: download from storage with auth
            print(f"[OCR] Download image: {storage_path}", flush=True)
            try:
                dl_url = f"http://storage:5000/object/invoices/{storage_path}"
                req = urllib.request.Request(dl_url,
                    headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}, method="GET")
                with urllib.request.urlopen(req, timeout=15) as resp:
                    file_data = resp.read()
                print(f"[OCR] Downloaded {len(file_data)} bytes", flush=True)
                img_b64 = base64.b64encode(file_data).decode()
                ocr_data, err = call_baidu_ocr(img_b64, "vat_invoice")
                if err:
                    ocr_data, err = call_baidu_ocr(img_b64, "general")
                if ocr_data and not err:
                    parsed = parse_ocr_result(ocr_data)
                    updates = {"raw_ocr_text": str(ocr_data)[:500]}
                    for k in ["invoice_number","invoice_date","seller_name","total_amount","project_location"]:
                        v = parsed.get(k)
                        if v: updates[k] = v
                    # v4.19.3 发票号级去重：同号已存在时合并到旧记录并删除当前
                    dup = find_duplicate_invoice(parsed, invoice_id)
                    if dup:
                        merge_duplicate_invoice(invoice_id, storage_path, dup, updates)
                        print(f"[OCR] 检测到重复发票号 {parsed.get('invoice_number')}，已合并到 ID {dup['id']} 并删除 ID {invoice_id}", flush=True)
                        self._json(200, {"success": True, "data": {**parsed, "id": dup["id"], "merged": True}, "raw": str(ocr_data)[:500], "merged": True, "merged_id": dup["id"]})
                        return
                    supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                    self._json(200, {"success": True, "data": parsed, "raw": str(ocr_data)[:500]})
                    return
                self._json(200, {"success": False, "error": f"OCR failed: {err}"})
                return
            except Exception as e:
                print(f"[OCR] Download failed: {e}", flush=True)
                self._json(200, {"success": False, "need_image": True, "error": str(e)})
                return

        self._json(200, {"success": False, "error": "缺少图片数据", "need_image": True})

    def _json(self, status, data):
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, apikey")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())

    def log_message(self, format, *args):
        print(f"[OCR] {args[0]}", flush=True)

if __name__ == "__main__":
    load_categories_from_db()
    print(f"OCR Service v4.11 on 0.0.0.0:{PORT}", flush=True)
    print(f"  Baidu API: {'OK' if BAIDU_API_KEY else 'N/A'}", flush=True)
    print(f"  Download: gateway:8000 + SERVICE_KEY auth", flush=True)
    print(f"  DB Save: rest through gateway:8000 + SERVICE_KEY", flush=True)
    server = HTTPServer(("0.0.0.0", PORT), OCRHandler)
    print(f"  Listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
