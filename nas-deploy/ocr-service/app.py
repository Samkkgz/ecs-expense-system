#!/usr/bin/env python3
"""ECS 报销系统 - OCR 识别服务 (等同于 Supabase Edge Function: process-invoice)"""
import os, json, re, base64, io
from http.server import HTTPServer, BaseHTTPRequestHandler

import requests

# 百度 OCR 配置
BAIDU_API_KEY = os.environ.get("BAIDU_API_KEY", "")
BAIDU_SECRET_KEY = os.environ.get("BAIDU_SECRET_KEY", "")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "http://kong:8000")
SERVICE_KEY = os.environ.get("SERVICE_KEY", "")
PORT = int(os.environ.get("PORT", 9000))

# 中国城市列表
CHINA_CITIES = [
    "广州","深圳","珠海","汕头","佛山","韶关","湛江","肇庆","江门","茂名",
    "惠州","梅州","汕尾","河源","阳江","清远","东莞","中山","潮州","揭阳","云浮",
    "北京","上海","天津","重庆",
    "南京","苏州","无锡","常州","镇江","扬州","南通","徐州","杭州","宁波",
    "温州","嘉兴","绍兴","金华","成都","武汉","长沙","西安","郑州","济南",
    "青岛","大连","沈阳","厦门","福州","合肥","昆明","贵阳","南宁","海口",
    "三亚","拉萨","兰州","西宁","银川","乌鲁木齐","呼和浩特","石家庄",
    "太原","哈尔滨","长春","南昌","香港","澳门","台北","曼谷","新加坡"
]

def detect_city(text):
    if not text: return None
    for city in CHINA_CITIES:
        if city in str(text): return city
    return None

def baidu_access_token():
    if not BAIDU_API_KEY or not BAIDU_SECRET_KEY:
        return None
    try:
        resp = requests.get(
            "https://aip.baidubce.com/oauth/2.0/token",
            params={"grant_type": "client_credentials", "client_id": BAIDU_API_KEY, "client_secret": BAIDU_SECRET_KEY},
            timeout=10
        )
        return resp.json().get("access_token")
    except:
        return None

def call_baidu_ocr(image_base64, ocr_type="vat_invoice"):
    token = baidu_access_token()
    if not token: return None, "Token获取失败"
    try:
        resp = requests.post(
            f"https://aip.baidubce.com/rest/2.0/ocr/v1/{ocr_type}",
            params={"access_token": token},
            data={"image": image_base64},
            timeout=30
        )
        result = resp.json()
        if "error_code" in result:
            return None, result.get("error_msg", "未知错误")
        return result, None
    except Exception as e:
        return None, str(e)

def parse_ocr_result(ocr_data):
    result = {}
    if not ocr_data: return result
    if isinstance(ocr_data, str):
        text = ocr_data
    else:
        raw = ocr_data.get("words_result", [])
        if isinstance(raw, dict):
            parts = []
            for v in raw.values():
                if isinstance(v, dict): parts.append(v.get("words", ""))
                elif isinstance(v, str): parts.append(v)
            text = " ".join(parts)
        else:
            text = " ".join(w.get("words", "") for w in raw) if raw else ""
    text = re.sub(r"\s+", "", text)
    
    # 发票号码
    m = re.search(r"(?:发票|号码|票号)\s*[：:]*\s*(\d{8,25})", text)
    if m: result["invoice_number"] = m.group(1)
    if not result.get("invoice_number"):
        m2 = re.search(r"(\d{10,20})", text)
        if m2: result["invoice_number"] = m2.group(1)
    
    # 日期
    m = re.search(r"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日", text)
    if m:
        result["invoice_date"] = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    if not result.get("invoice_date"):
        m = re.search(r"(\d{4})[-年]\s*(\d{1,2})[-月]\s*(\d{1,2})", text)
        if m and m.group(1) > "2000":
            result["invoice_date"] = f"{m.group(1)}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    
    # 金额
    patterns = [
        r"价税合计[^)]*\）[^]*?[\u00a5\uffe5]?\s*(\d+\.\d{2})",
        r"[\u00a5\uffe5]\s*(\d+\.\d{2})",
        r"合计\s*[\u00a5\uffe5]?\s*(\d+\.\d{2})",
    ]
    for p in patterns:
        m = re.search(p, text)
        if m:
            result["total_amount"] = float(m.group(1))
            break
    if "total_amount" not in result:
        nums = re.findall(r"(\d+\.\d{2})", text)
        if nums: result["total_amount"] = float(max(nums, key=float))
    
    # 商家名称
    for prefix in ["销售方", "收款方", "商户名称", "销货方"]:
        idx = text.find(prefix)
        if idx >= 0:
            chunk = text[idx:idx+60]
            m = re.search(r"名称\s*[：:]*\s*([^\s\n]{2,30})", chunk)
            if m:
                result["seller_name"] = m.group(1).strip()
                break
            m = re.search(r"([\u4e00-\u9fff]{2,15}(?:有限公司|经营部|商行|店|餐厅|酒店|宾馆))", chunk)
            if m:
                result["seller_name"] = m.group(0)
                break
    
    # 地点
    loc = detect_city(text)
    if loc: result["project_location"] = loc
    
    return result

def auto_categorize(seller_name, item_desc):
    s = (seller_name or "").lower()
    i = (item_desc or "").lower()
    
    seller_city = detect_city(seller_name)
    desc_city = detect_city(item_desc)
    city = seller_city or desc_city
    is_out_of_town = city and city != "广州"
    
    cat_name = None
    if any(kw in i for kw in ["铁路","高铁","航空","机票","火车"]) or any(kw in s for kw in ["航空","铁路"]):
        cat_name = "出差交通费"
    elif any(kw in s for kw in ["油","石油","石化","加油站"]):
        cat_name = "出差交通费"
    elif any(kw in s for kw in ["酒店","宾馆","住宿","旅店","民宿"]):
        cat_name = "出差住房费"
    elif any(kw in s for kw in ["餐饮","餐厅","饭","酒","茶","咖啡","烘焙","面包","甜品"]):
        cat_name = "客情餐饮费" if any(kw in i for kw in ["客情","招待","客户"]) else ("出差餐饮费" if is_out_of_town else "日常餐饮费")
        cat_name = "出差住房费"
    elif any(kw in s for kw in ["通讯","通信","移动","联通","电信"]):
        cat_name = "通讯费"
    elif any(kw in s for kw in ["文具","办公","打印","墨盒"]):
        cat_name = "办公用品"
    
    return cat_name, city

def supabase_api(path, method="GET", body=None):
    """调用本地 Supabase REST API"""
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }
    try:
        if method == "GET":
            resp = requests.get(url, headers=headers, timeout=10)
        elif method == "PATCH":
            resp = requests.patch(url, headers=headers, json=body, timeout=10)
        else:
            return None
        if resp.status_code in (200, 201):
            return resp.json()
        return None
    except:
        return None

class OCRHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self._cors_headers()
        self.end_headers()
    
    def do_POST(self):
        if self.path != "/functions/v1/process-invoice":
            self._json_response(404, {"error": "Not found"})
            return
        
        try:
            content_length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(content_length)) if content_length > 0 else {}
        except:
            self._json_response(400, {"error": "Invalid JSON"})
            return
        
        record = body.get("record") or body
        storage_path = record.get("storage_path", "")
        invoice_id = record.get("id")
        image_base64 = record.get("image_base64")
        
        if not invoice_id:
            self._json_response(400, {"error": "缺少 invoice id"})
            return
        
        print(f"[OCR] 请求 invoice_id={invoice_id}, path={storage_path}, image={bool(image_base64)}")
        
        if image_base64:
            # 百度 OCR 识别
            ocr_data, err = call_baidu_ocr(image_base64, "vat_invoice")
            if err:
                print(f"[OCR] 增值税发票失败: {err}, 降级到通用识别")
                ocr_data, err = call_baidu_ocr(image_base64, "general")
            
            if ocr_data and not err:
                parsed = parse_ocr_result(ocr_data)
                print(f"[OCR] 识别结果: {parsed}")
                
                # 自动分类
                cat_name, city = auto_categorize(
                    parsed.get("seller_name", ""),
                    parsed.get("item_description", "")
                )
                
                # 保存到数据库
                updates = {
                    "invoice_number": parsed.get("invoice_number", ""),
                    "invoice_date": parsed.get("invoice_date", ""),
                    "seller_name": parsed.get("seller_name", ""),
                    "total_amount": parsed.get("total_amount", 0),
                    "project_location": parsed.get("project_location", "") or city or "",
                    "raw_ocr_text": str(ocr_data)[:500],
                    "status": "pending"
                }
                
                # 更新发票
                result = supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                
                # 设置分类
                if cat_name:
                    cat_result = supabase_api(f"expense_categories?name=eq.{cat_name}&select=id")
                    if cat_result and len(cat_result) > 0:
                        cat_id = cat_result[0]["id"]
                        supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", {"category_id": cat_id})
                        updates["category_id"] = cat_id
                
                self._json_response(200, {"success": True, "data": updates})
                return
            else:
                self._json_response(200, {"success": False, "error": f"OCR失败: {err}"})
                return
        
        # 无图片数据 - 尝试从存储下载PDF提取文字
        if storage_path:
            try:
                dl_url = f"{SUPABASE_URL}/storage/v1/object/invoices/{storage_path}"
                dl_resp = requests.get(dl_url, headers={"apikey": SERVICE_KEY}, timeout=30)
                if dl_resp.status_code == 200:
                    # 尝试用 pdfplumber 提取文字
                    try:
                        import pdfplumber
                        pdf_file = io.BytesIO(dl_resp.content)
                        with pdfplumber.open(pdf_file) as pdf:
                            text = ""
                            for page in pdf.pages[:3]:
                                t = page.extract_text() or ""
                                text += t + "\n"
                        if text.strip() and len(text.strip()) > 5 and "(cid:" not in text:
                            parsed = parse_ocr_result({"words_result": [{"words": text}]})
                            updates = {
                                "invoice_number": parsed.get("invoice_number", ""),
                                "invoice_date": parsed.get("invoice_date", ""),
                                "seller_name": parsed.get("seller_name", ""),
                                "total_amount": parsed.get("total_amount", 0),
                                "project_location": parsed.get("project_location", ""),
                                "raw_ocr_text": text[:500],
                                "status": "pending"
                            }
                            supabase_api(f"invoices?id=eq.{invoice_id}", "PATCH", updates)
                            self._json_response(200, {"success": True, "data": updates})
                            return
                    except ImportError:
                        pass
                    
                    self._json_response(200, {"success": False, "error": "无法提取文字，请使用图片识别", "need_image": True})
                    return
            except Exception as e:
                print(f"[OCR] 下载文件失败: {e}")
        
        self._json_response(200, {"success": False, "error": "缺少图片数据"})
    
    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization, apikey")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
    
    def _json_response(self, status, data):
        self.send_response(status)
        self._cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode())
    
    def log_message(self, format, *args):
        print(f"[OCR] {args[0]}")

if __name__ == "__main__":
    print(f"🚀 OCR 服务启动: 0.0.0.0:{PORT}")
    print(f"   Supabase URL: {SUPABASE_URL}")
    print(f"   百度OCR: {'已配置' if BAIDU_API_KEY else '未配置'}")
    server = HTTPServer(("0.0.0.0", PORT), OCRHandler)
    server.serve_forever()
