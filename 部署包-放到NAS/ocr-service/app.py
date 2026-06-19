#!/usr/bin/env python3
"""ECS v4.8 - OCR 识别服务（纯 stdlib，无需 pip install）"""
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
        err_body = e.read().decode("utf-8", errors="replace")[:300]
        print(f"[HTTP] {method} {url} → {e.code} {err_body}", flush=True)
        return e.code, f"{e.code} {err_body}"
    except Exception as e:
        print(f"[HTTP] {method} {url} → {e}", flush=True)
        return 0, str(e)


def detect_city(text):
    if not text: return None
    for city in CHINA_CITIES:
        if city in str(text): return city
    return None


def baidu_access_token():
    if not BAIDU_API_KEY or not BAIDU_SECRET_KEY: return None
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
    body = urllib.parse.urlencode({"image": image_base64}).encode()
    try:
        req = urllib.request.Request(url, data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
        if "error_code" in result:
            return None, result.get("error_msg", "未知OCR错误")
        return result, None
    except Exception as e:
        return None, str(e)


def parse_ocr_result(ocr_data):
    """Parse Baidu OCR result - prioritize structured fields, fall back to regex"""
    result = {}
    if not ocr_data: return result

    # Normalize: handle both direct words_result and wrapper
    if isinstance(ocr_data, str):
        raw_dict = {}
        text_blob = ocr_data
    else:
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

    # === Structured field extraction (Baidu VAT invoice) ===
    # Invoice number
    for f in ["InvoiceNum", "InvoiceNumDigit", "InvoiceCode", "InvoiceNumConfirm"]:
        v = raw_dict.get(f, "")
        if v and re.search(r"\d{8}", str(v)):
            result["invoice_number"] = str(v).strip(); break

    # Date
    date_str = str(raw_dict.get("InvoiceDate", ""))
    m = re.search(r"(\d{4})[年\-./](\d{1,2})[月\-./](\d{1,2})", date_str)
    if m and 2020 <= int(m.group(1)) <= 2030:
        result["invoice_date"] = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"

    # Amount - prefer direct fields
    for f in ["AmountInFiguers", "TotalAmount"]:
        v = str(raw_dict.get(f, "")).replace(",", "").replace("，", "")
        try:
            amt = float(re.search(r"(\d+\.?\d*)", v).group(1))
            if amt > 0: result["total_amount"] = amt; break
        except: pass

    # Amount from CommodityAmount (sum or last row)
    if "total_amount" not in result:
        ca = raw_dict.get("CommodityAmount", [])
        if isinstance(ca, list):
            total = 0
            for item in ca:
                try:
                    w = item.get("word", item.get("words", "0"))
                    total += float(str(w).replace(",",""))
                except: pass
            if total > 0: result["total_amount"] = total

    # Seller name
    for f in ["SellerName", "Seller"]:
        v = str(raw_dict.get(f, "")).strip()
        if v and len(v) >= 2 and not v.startswith("*"):
            result["seller_name"] = v; break

    # City from addresses
    for f in ["SellerAddress", "PurchaserAddress", "SellerBank"]:
        city = detect_city(str(raw_dict.get(f, "")))
        if city: result["project_location"] = city; break

    # === Fallback: regex on flattened text for missed fields ===
    if not result.get("invoice_number"):
        m = re.search(r"(?:发票号码|发票号|号码|票号|No[\.\s]*)[：:]*\s*(\d{8})", text_blob)
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
            r"[¥￥]\s*(\d+\.\d{2})",
            r"合计\s*[¥￥]?\s*(\d+\.\d{2})",
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
                # Look for name: pattern
                m = re.search(r"称\s*[：:]*\s*([^\s\n]{2,30})", chunk)
                if m: result["seller_name"] = m.group(1).strip(); break
                # Or just grab the next text after prefix
                m = re.search(r"[：:]\s*([^\s\n]{2,30})", chunk)
                if m: result["seller_name"] = m.group(1).strip(); break

    if not result.get("project_location"):
        city = detect_city(text_blob)
        if city: result["project_location"] = city

    return result


def flatten_words(raw_dict):
    """Flatten Baidu words_result dict + list values into a single text blob"""
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

# 类目关键词缓存（启动时从数据库加载）
CATEGORY_KEYWORDS = {}

# 类目→商家关键词映射（从类目名自动生成 + 常用商家词库）
MERCHANT_KW = {
    "办公用品": ["文具","办公","打印","复印","耗材","墨盒","硒鼓","纸张","纸业","文件夹","得力","晨光","齐心","惠普","佳能"],
    "出差交通费": ["航空","机票","火车","高铁","加油","石油","石化","航司","东方航空","南方航空","国航","海航"],
    "出差住房费": ["酒店","宾馆","民宿","旅馆","客栈","公寓","招待所","度假","如家","锦江","汉庭","全季","维也纳","希尔顿","万豪","洲际","华住"],
    "通讯费": ["电信","移动","联通","通讯","通信","话费","流量","宽带","中国电信","中国移动","中国联通"],
    "外出交通费": ["滴滴","出租","停车","公交","地铁","充电","高德","曹操","T3","首汽","嘀嗒","顺丰","中通","圆通","韵达"],
}
# 餐饮类共用关键词
FOOD_KW = ["餐厅","饭店","酒楼","酒家","快餐","小吃","奶茶","咖啡","食堂","食府","火锅","烧烤","料理","面馆","米粉","包子","馒头","饺子","烘焙","蛋糕","甜品","饮吧","餐","鸡","鸭","鱼","虾","蟹","海鲜","牛排","披萨","汉堡","麦当劳","肯德基","必胜客","海底捞","西贝","太二","探鱼","点都德","陶陶居","广州酒家","炳胜"]

def load_categories_from_db():
    """从 Supabase 加载真实类目并构建关键词映射"""
    global CATEGORY_KEYWORDS
    ok, cats = supabase_api("expense_categories?select=id,name,description", "GET")
    if not ok or not isinstance(cats, list):
        print("[OCR] 加载类目失败", flush=True)
        CATEGORY_KEYWORDS = {}
        return
    for c in cats:
        name = c.get("name", "")
        cid = c.get("id")
        kws = set()
        # 1. 从类目名拆词
        for text in [name, c.get("description", "")]:
            text = text.replace("费","").replace("支出","")
            for i in range(len(text)):
                for j in (2,3):
                    if i+j <= len(text): kws.add(text[i:i+j])
        # 2. 预置商家关键词
        if "餐饮" in name:
            kws.update(FOOD_KW)
        if name in MERCHANT_KW:
            kws.update(MERCHANT_KW[name])
        CATEGORY_KEYWORDS[name] = {"id": cid, "keywords": kws}
    print(f"[OCR] 加载 {len(CATEGORY_KEYWORDS)} 个类目", flush=True)

def auto_categorize(seller_name, item_desc):
    """根据商家名匹配数据库中的真实类目"""
    if not CATEGORY_KEYWORDS:
        return None
    s = (seller_name or "").lower()
    d = (item_desc or "").lower()
    combined = s + " " + d
    
    best_match = None
    best_score = 0
    for cat_name, info in CATEGORY_KEYWORDS.items():
        score = 0
        for kw in info["keywords"]:
            if kw in combined:
                score += len(kw)  # 越长关键词匹配越精准
        if score > best_score:
            best_score = score
            best_match = cat_name
    return best_match


def supabase_api(path, method="GET", body=None):
    """Call Supabase REST API with service_role. Returns (ok_bool, data_or_error)."""
    url = f"{SUPABASE_URL}/rest/v1/{path}"
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


class OCRHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, apikey")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.end_headers()

    def do_POST(self):
        # Health check
        if self.path in ("/", "/functions/v1/"):
            self._json(200, {"status": "ok", "deps": "stdlib"})
            return

        # OCR routes
        if self.path not in ("/process-invoice", "/functions/v1/process-invoice", "/ocr"):
            self._json(404, {"error": f"Not found: {self.path}"})
            return

        try:
            cl = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(cl)) if cl > 0 else {}
        except Exception:
            self._json(400, {"error": "Invalid JSON"})
            return

        record = body.get("record") or body
        storage_path = record.get("storage_path", "")
        invoice_id = record.get("id")
        image_base64 = record.get("image_base64")

        # 兼容旧路径：去除 invoices/ 前缀
        if storage_path.startswith("invoices/"):
            storage_path = storage_path[9:]

        if not invoice_id:
            self._json(400, {"error": "missing invoice id"})
            return

        print(f"[OCR] id={invoice_id} path={storage_path} has_image={'YES' if image_base64 else 'NO'}", flush=True)

        if image_base64:
            ocr_data, err = call_baidu_ocr(image_base64, "vat_invoice")
            if err:
                print(f"[OCR] vat_invoice failed: {err}, trying general", flush=True)
                ocr_data, err = call_baidu_ocr(image_base64, "general")

            if ocr_data and not err:
                parsed = parse_ocr_result(ocr_data)
                print(f"[OCR] parsed: {json.dumps(parsed, ensure_ascii=False)}", flush=True)

                city = parsed.get("project_location", "")

                updates = {"status": "pending"}
                for k in ["invoice_number","invoice_date","seller_name","total_amount","project_location","raw_ocr_text"]:
                    v = parsed.get(k)
                    if v: updates[k] = v
                updates["raw_ocr_text"] = str(ocr_data)[:500]
                if city: updates["project_location"] = city

                ok, api_result = supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                if not ok:
                    print(f"[OCR] ❌ PATCH failed: {api_result}", flush=True)
                    self._json(200, {"success": False, "error": f"写入数据库失败: {api_result}"})
                    return
                print(f"[OCR] ✅ PATCH ok", flush=True)


                self._json(200, {"success": True, "data": updates})
                return
            else:
                self._json(200, {"success": False, "error": f"OCR失败: {err}"})
                return

        # No base64 - try downloading from storage
        if storage_path:
            dl_url = f"{SUPABASE_URL}/storage/v1/object/invoices/{storage_path}"
            print(f"[OCR] downloading: {dl_url}", flush=True)
            try:
                req = urllib.request.Request(dl_url,
                    headers={"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}, method="GET")
                with urllib.request.urlopen(req, timeout=30) as resp:
                    file_data = resp.read()

                ext = os.path.splitext(storage_path)[1].lower()
                if ext == ".pdf":
                    try:
                        import pdfplumber
                        with pdfplumber.open(io.BytesIO(file_data)) as pdf:
                            text = "\n".join((p.extract_text() or "") for p in pdf.pages[:3])
                        if text.strip() and len(text.strip()) > 5 and "(cid:" not in text:
                            parsed = parse_ocr_result({"words_result": [{"words": text}]})
                            updates = {"status": "pending", "raw_ocr_text": text[:500]}
                            for k in ["invoice_number","invoice_date","seller_name","total_amount","project_location"]:
                                v = parsed.get(k)
                                if v: updates[k] = v
                            ok, _ = supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                            self._json(200, {"success": ok, "data": updates})
                            return
                    except ImportError:
                        pass
                    self._json(200, {"success": False, "error": "PDF需要图片识别", "need_image": True})
                else:
                    img_b64 = base64.b64encode(file_data).decode()
                    ocr_data, err = call_baidu_ocr(img_b64, "vat_invoice")
                    if err: ocr_data, err = call_baidu_ocr(img_b64, "general")
                    if ocr_data and not err:
                        parsed = parse_ocr_result(ocr_data)
                        updates = {"status": "pending", "raw_ocr_text": str(ocr_data)[:500]}
                        for k in ["invoice_number","invoice_date","seller_name","total_amount","project_location"]:
                            v = parsed.get(k)
                            if v: updates[k] = v
                        ok, _ = supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                        self._json(200, {"success": ok, "data": updates})
                    else:
                        self._json(200, {"success": False, "error": f"OCR失败: {err}"})
                return
            except Exception as e:
                print(f"[OCR] download error: {e}", flush=True)
                self._json(200, {"success": False, "error": str(e)})
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
    print(f"OCR Service v4.5 on 0.0.0.0:{PORT}", flush=True)
    print(f"  stdlib-only | Baidu: {'OK' if BAIDU_API_KEY else 'N/A'} | Supabase: {SUPABASE_URL}", flush=True)
    server = HTTPServer(("0.0.0.0", PORT), OCRHandler)
    print(f"  Listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
