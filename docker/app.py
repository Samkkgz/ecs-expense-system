#!/usr/bin/env python3
"""ECS 报销管理系统 - 自托管版 (Flask后端)"""

import os, sqlite3, uuid, hashlib, json, re, io, base64
from datetime import datetime, timedelta
from functools import wraps
from pathlib import Path

import requests
from flask import (
    Flask, request, jsonify, session, send_from_directory,
    send_file, redirect, url_for
)

# ── 配置 ──────────────────────────────────────────────
BASE_DIR = Path(__file__).parent
DATA_DIR = Path(os.environ.get("APP_DATA_DIR", BASE_DIR / "data"))
DB_PATH = DATA_DIR / "database.db"
INVOICES_DIR = DATA_DIR / "invoices"
BACKUPS_DIR = DATA_DIR / "backups"
PORT = int(os.environ.get("PORT", 8888))
SECRET_KEY = os.environ.get("SECRET_KEY", "change-this-secret-key")
ADMIN_EMAIL = os.environ.get("ADMIN_EMAIL", "admin@ecsomni.com")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "admin123")
BAIDU_API_KEY = os.environ.get("BAIDU_API_KEY", "")
BAIDU_SECRET_KEY = os.environ.get("BAIDU_SECRET_KEY", "")

app = Flask(__name__, static_folder=str(BASE_DIR / "static"), static_url_path="")
app.secret_key = SECRET_KEY
app.permanent_session_lifetime = timedelta(days=30)

# 中国城市列表（用于自动识别地点）
CHINA_CITIES = ["广州","深圳","珠海","佛山","东莞","中山","惠州",
    "北京","上海","天津","重庆","杭州","南京","苏州","成都","武汉",
    "长沙","西安","郑州","济南","青岛","大连","沈阳","厦门","福州",
    "合肥","昆明","贵阳","南宁","海口","三亚","香港","澳门"]

# ── 工具函数 ──────────────────────────────────────────
def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

def hash_password(password):
    return hashlib.sha256(password.encode()).hexdigest()

def detect_city(text):
    if not text: return None
    for c in CHINA_CITIES:
        if c in str(text): return c
    return None

def current_user_id():
    return session.get("user_id")

def require_auth(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not current_user_id():
            return jsonify({"error": "未登录"}), 401
        return f(*args, **kwargs)
    return wrapper

def require_admin(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        uid = current_user_id()
        if not uid: return jsonify({"error": "未登录"}), 401
        db = get_db()
        user = db.execute("SELECT role FROM users WHERE id=?", (uid,)).fetchone()
        db.close()
        if not user or user["role"] not in ("admin", "super_admin"):
            return jsonify({"error": "无权限"}), 403
        return f(*args, **kwargs)
    return wrapper

def is_admin():
    uid = current_user_id()
    if not uid: return False
    db = get_db()
    user = db.execute("SELECT role FROM users WHERE id=?", (uid,)).fetchone()
    db.close()
    return user and user["role"] in ("admin", "super_admin")

# ── 数据库初始化 ─────────────────────────────────────
def init_db():
    INVOICES_DIR.mkdir(parents=True, exist_ok=True)
    BACKUPS_DIR.mkdir(parents=True, exist_ok=True)
    
    db = get_db()
    with open(BASE_DIR / "schema.sql") as f:
        db.executescript(f.read())
    
    # 创建默认管理员
    existing = db.execute("SELECT id FROM users WHERE email=?", (ADMIN_EMAIL,)).fetchone()
    if not existing:
        uid = str(uuid.uuid4())
        db.execute(
            "INSERT INTO users (id, email, name, password_hash, role, status) VALUES (?,?,?,?,?,?)",
            (uid, ADMIN_EMAIL, "管理员", hash_password(ADMIN_PASSWORD), "super_admin", "active")
        )
        print(f"  → 管理员创建: {ADMIN_EMAIL}")
    db.commit()
    db.close()
    print(f"  → 数据库: {DB_PATH}")

# ── 页面路由 ──────────────────────────────────────────
@app.route("/")
def index():
    return send_from_directory(str(BASE_DIR / "static"), "index.html")

@app.route("/api/me")
@require_auth
def api_me():
    db = get_db()
    user = db.execute("SELECT id, email, name, role, status FROM users WHERE id=?", (current_user_id(),)).fetchone()
    db.close()
    if not user: return jsonify({"error": "用户不存在"}), 404
    return jsonify(dict(user))

# ── 认证 ──────────────────────────────────────────────
@app.route("/api/auth/login", methods=["POST"])
def auth_login():
    data = request.get_json() or {}
    email = data.get("email", "").strip().lower()
    password = data.get("password", "")
    
    if not email or not password:
        return jsonify({"error": "请输入邮箱和密码"}), 400
    
    db = get_db()
    user = db.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
    
    if not user:
        # 自动注册（第一个注册的用户自动成为超级管理员）
        existing_count = db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        first_user = existing_count == 0
        role = "super_admin" if first_user else "member"
        uid = str(uuid.uuid4())
        db.execute(
            "INSERT INTO users (id, email, name, password_hash, role, status) VALUES (?,?,?,?,?,?)",
            (uid, email, email.split("@")[0], hash_password(password), role, "active")
        )
        db.commit()
        session["user_id"] = uid
        session.permanent = True
        db.close()
        return jsonify({"success": True, "message": f"注册成功{'（超级管理员）' if first_user else ''}", "is_new": True})
        db.commit()
        session["user_id"] = uid
        session.permanent = True
        db.close()
        return jsonify({"success": True, "message": "注册成功", "is_new": True})
    
    if user["status"] == "inactive":
        db.close()
        return jsonify({"error": "账号已被停用"}), 403
    
    if user["password_hash"] != hash_password(password):
        db.close()
        return jsonify({"error": "密码错误"}), 401
    
    session["user_id"] = user["id"]
    session.permanent = True
    db.close()
    return jsonify({"success": True, "message": "登录成功"})

@app.route("/api/auth/logout", methods=["POST"])
def auth_logout():
    session.clear()
    return jsonify({"success": True})

@app.route("/api/auth/register", methods=["POST"])
def auth_register():
    data = request.get_json() or {}
    email = data.get("email", "").strip().lower()
    password = data.get("password", "")
    name = data.get("name", email.split("@")[0])
    
    if not email or not password:
        return jsonify({"error": "请输入邮箱和密码"}), 400
    if len(password) < 4:
        return jsonify({"error": "密码至少4位"}), 400
    
    db = get_db()
    existing = db.execute("SELECT id FROM users WHERE email=?", (email,)).fetchone()
    if existing:
        db.close()
        return jsonify({"error": "该邮箱已注册"}), 409
    
    uid = str(uuid.uuid4())
    db.execute(
        "INSERT INTO users (id, email, name, password_hash) VALUES (?,?,?,?)",
        (uid, email, name, hash_password(password))
    )
    db.commit()
    db.close()
    return jsonify({"success": True, "message": "注册成功"})

# ── 发票 CRUD ─────────────────────────────────────────
@app.route("/api/invoices", methods=["GET"])
@require_auth
def list_invoices():
    db = get_db()
    query = "SELECT * FROM invoices WHERE 1=1"
    params = []
    
    # 用户隔离
    req_user_id = request.args.get("user_id")
    if req_user_id:
        query += " AND uploaded_by=?"
        params.append(req_user_id)
    elif not is_admin():
        query += " AND uploaded_by=?"
        params.append(current_user_id())
    
    # 筛选
    filter_month = request.args.get("month")
    filter_cat = request.args.get("category")
    filter_status = request.args.get("status")
    search = request.args.get("search")
    
    if filter_month:
        query += " AND invoice_date >= ? AND invoice_date <= ?"
        params.append(f"{filter_month}-01")
        params.append(f"{filter_month}-31")
    if filter_cat:
        query += " AND category_id=?"
        params.append(filter_cat)
    if filter_status:
        query += " AND status=?"
        params.append(filter_status)
    
    query += " ORDER BY created_at DESC"
    
    # 限制返回数量
    limit = request.args.get("limit")
    if limit:
        query += " LIMIT ?"
        params.append(int(limit))
    
    rows = db.execute(query, params).fetchall()
    db.close()
    
    results = [dict(r) for r in rows]
    if search:
        s = search.lower()
        results = [r for r in results if s in (r.get("invoice_number") or "").lower()
                   or s in (r.get("seller_name") or "").lower()
                   or s in (r.get("item_description") or "").lower()]
    
    return jsonify(results)

@app.route("/api/invoices", methods=["POST"])
@require_auth
def create_invoice():
    data = request.get_json() or {}
    storage_path = data.get("storage_path")
    original_filename = data.get("original_filename", "")
    file_size = data.get("file_size", 0)
    
    if not storage_path:
        return jsonify({"error": "缺少 storage_path"}), 400
    
    db = get_db()
    
    # 去重检查：同名+同大小视为重复
    if original_filename and file_size:
        dup = db.execute(
            "SELECT id FROM invoices WHERE original_filename=? AND file_size=? LIMIT 1",
            (original_filename, file_size)
        ).fetchone()
        if dup:
            db.close()
            return jsonify({"error": "重复文件", "message": "文件已存在"}), 409
    
    db.execute("""
        INSERT INTO invoices (storage_path, original_filename, file_size, category_id,
            project_location, uploaded_by, status, invoice_date, created_at)
        VALUES (?,?,?,?,?,?,?,?,datetime('now','localtime'))
    """, (
        storage_path,
        original_filename,
        file_size,
        data.get("category_id"),
        data.get("project_location"),
        current_user_id(),
        "pending",
        data.get("invoice_date")
    ))
    db.commit()
    invoice_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]
    db.close()
    return jsonify({"success": True, "id": invoice_id})

@app.route("/api/invoices/<int:invoice_id>", methods=["PUT"])
@require_auth
def update_invoice(invoice_id):
    data = request.get_json() or {}
    fields = ["invoice_number","invoice_date","seller_name","total_amount",
              "category_id","project_location","expense_note","item_description","status"]
    updates = []
    params = []
    for f in fields:
        if f in data:
            updates.append(f"{f}=?")
            params.append(data[f])
    
    if not updates:
        return jsonify({"error": "没有要更新的字段"}), 400
    
    # 自动检测地点
    if "project_location" not in data or not data.get("project_location"):
        seller = data.get("seller_name", "")
        loc = detect_city(seller) or detect_city(data.get("item_description", ""))
        if loc:
            updates.append("project_location=?")
            params.append(loc)
    
    updates.append("updated_at=?")
    params.append(datetime.now().isoformat())
    params.append(invoice_id)
    
    db = get_db()
    db.execute(f"UPDATE invoices SET {','.join(updates)} WHERE id=?", params)
    db.commit()
    db.close()
    return jsonify({"success": True})

@app.route("/api/invoices/<int:invoice_id>", methods=["DELETE"])
@require_auth
def delete_invoice(invoice_id):
    db = get_db()
    invoice = db.execute("SELECT * FROM invoices WHERE id=?", (invoice_id,)).fetchone()
    if not invoice:
        db.close()
        return jsonify({"error": "发票不存在"}), 404
    
    uid = current_user_id()
    if invoice["uploaded_by"] != uid and not is_admin():
        db.close()
        return jsonify({"error": "无权限删除此发票"}), 403
    
    # 删除存储文件
    filepath = INVOICES_DIR / invoice["storage_path"]
    if filepath.exists():
        filepath.unlink()
    
    db.execute("DELETE FROM invoices WHERE id=?", (invoice_id,))
    db.commit()
    db.close()
    return jsonify({"success": True, "message": "已删除"})

@app.route("/api/invoices/stats")
@require_auth
def invoice_stats():
    db = get_db()
    year = request.args.get("year", str(datetime.now().year))
    user_filter = ""
    params = [year]
    
    if not is_admin():
        user_filter = " AND uploaded_by=?"
        params.append(current_user_id())
    
    # 已通过的年度统计
    quarter = request.args.get("quarter")
    month = request.args.get("month")
    
    if quarter:
        q = int(quarter)
        sm = str((q-1)*3+1).zfill(2)
        em = str(q*3).zfill(2)
        date_start = f"{year}-{sm}-01"
        date_end = f"{year}-{em}-31"
    elif month:
        date_start = f"{year}-{month}-01"
        date_end = f"{year}-{month}-31"
    else:
        date_start = f"{year}-01-01"
        date_end = f"{year}-12-31"
    
    rows = db.execute(f"""
        SELECT total_amount, category_id, invoice_date, status, uploaded_by
        FROM invoices WHERE invoice_date >= ? AND invoice_date <= ?
        AND status='approved' {user_filter}
    """, [date_start, date_end] + params[1:]).fetchall()
    
    total = sum(r["total_amount"] or 0 for r in rows)
    
    # 月度统计
    monthly = [0]*12
    for r in rows:
        if r["invoice_date"]:
            m = int(r["invoice_date"].split("-")[1]) - 1
            monthly[m] += r["total_amount"] or 0
    
    # 类目统计
    cat_totals = {}
    for r in rows:
        cat = r["category_id"]
        cat_totals[cat] = (cat_totals.get(cat) or 0) + (r["total_amount"] or 0)
    
    db.close()
    return jsonify({
        "total": round(total, 2),
        "count": len(rows),
        "monthly": monthly,
        "category_totals": cat_totals,
        "year": int(year)
    })

# ── 文件上传/下载 ────────────────────────────────────
@app.route("/api/upload", methods=["POST"])
@require_auth
def upload_file():
    if "file" not in request.files:
        return jsonify({"error": "没有文件"}), 400
    
    file = request.files["file"]
    if file.filename == "":
        return jsonify({"error": "文件名为空"}), 400
    
    # 检查格式
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in (".pdf", ".png", ".jpg", ".jpeg", ".bmp"):
        return jsonify({"error": "不支持的文件格式"}), 400
    
    # 生成存储路径: 年/月/时间戳.扩展名
    now = datetime.now()
    year_month = f"{now.year}/{now.month:02d}"
    save_dir = INVOICES_DIR / year_month
    save_dir.mkdir(parents=True, exist_ok=True)
    
    storage_name = f"{int(now.timestamp() * 1000)}{ext}"
    storage_path = f"{year_month}/{storage_name}"
    filepath = save_dir / storage_name
    
    file.save(str(filepath))
    file_size = filepath.stat().st_size
    
    return jsonify({
        "success": True,
        "storage_path": storage_path,
        "file_size": file_size,
        "original_filename": file.filename
    })

@app.route("/api/files/<path:filepath>")
def serve_file(filepath):
    # 安全检查
    filepath = filepath.replace("..", "")
    full_path = INVOICES_DIR / filepath
    if not full_path.exists():
        return jsonify({"error": "文件不存在"}), 404
    return send_file(str(full_path))

# ── 类别管理 ──────────────────────────────────────────
@app.route("/api/categories", methods=["GET"])
def list_categories():
    db = get_db()
    rows = db.execute("SELECT * FROM expense_categories ORDER BY sort_order").fetchall()
    db.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/categories", methods=["POST"])
@require_auth
def create_category():
    data = request.get_json() or {}
    name = data.get("name", "").strip()
    if not name: return jsonify({"error": "类目名称不能为空"}), 400
    
    db = get_db()
    db.execute("INSERT INTO expense_categories (name, description, sort_order) VALUES (?,?,?)",
               (name, data.get("description", ""), data.get("sort_order", 99)))
    db.commit()
    cat_id = db.execute("SELECT last_insert_rowid()").fetchone()[0]
    db.close()
    return jsonify({"success": True, "id": cat_id})

@app.route("/api/categories/<int:cat_id>", methods=["PUT"])
@require_auth
def update_category(cat_id):
    data = request.get_json() or {}
    db = get_db()
    db.execute("UPDATE expense_categories SET name=?, description=?, sort_order=? WHERE id=?",
               (data.get("name"), data.get("description", ""), data.get("sort_order", 99), cat_id))
    db.commit()
    db.close()
    return jsonify({"success": True})

# ── 用户/配置文件 ─────────────────────────────────────
@app.route("/api/profiles", methods=["GET"])
@require_admin
def list_profiles():
    db = get_db()
    rows = db.execute("SELECT id, email, name, role, status, created_at FROM users ORDER BY created_at").fetchall()
    db.close()
    return jsonify([dict(r) for r in rows])

@app.route("/api/profiles", methods=["PUT"])
@require_auth
def update_profile():
    data = request.get_json() or {}
    db = get_db()
    if "name" in data:
        db.execute("UPDATE users SET name=? WHERE id=?", (data["name"], current_user_id()))
    db.commit()
    db.close()
    return jsonify({"success": True})

# ── 管理员 - 用户管理 ────────────────────────────────
@app.route("/api/admin/user", methods=["POST"])
@require_admin
def admin_create_user():
    data = request.get_json() or {}
    email = data.get("email", "").strip().lower()
    password = data.get("password", "123456")
    name = data.get("name", email.split("@")[0])
    role = data.get("role", "member")
    
    if not email: return jsonify({"error": "请输入邮箱"}), 400
    
    db = get_db()
    existing = db.execute("SELECT id FROM users WHERE email=?", (email,)).fetchone()
    if existing:
        db.close()
        return jsonify({"error": "该邮箱已存在"}), 409
    
    uid = str(uuid.uuid4())
    db.execute("INSERT INTO users (id, email, name, password_hash, role) VALUES (?,?,?,?,?)",
               (uid, email, name, hash_password(password), role))
    db.commit()
    db.close()
    return jsonify({"success": True, "message": f"用户 {email} 已创建"})

@app.route("/api/admin/user/<user_id>/role", methods=["PUT"])
@require_admin
def admin_update_role(user_id):
    data = request.get_json() or {}
    role = data.get("role", "member")
    db = get_db()
    db.execute("UPDATE users SET role=? WHERE id=?", (role, user_id))
    db.commit()
    db.close()
    return jsonify({"success": True})

@app.route("/api/admin/user/<user_id>/status", methods=["PUT"])
@require_admin
def admin_toggle_status(user_id):
    data = request.get_json() or {}
    status = data.get("status", "active")
    db = get_db()
    db.execute("UPDATE users SET status=? WHERE id=?", (status, user_id))
    db.commit()
    db.close()
    return jsonify({"success": True})

@app.route("/api/admin/user/<user_id>", methods=["DELETE"])
@require_admin
def admin_delete_user(user_id):
    if user_id == current_user_id():
        return jsonify({"error": "不能删除自己"}), 400
    
    db = get_db()
    # 删除用户的发票记录
    db.execute("DELETE FROM invoices WHERE uploaded_by=?", (user_id,))
    db.execute("DELETE FROM users WHERE id=?", (user_id,))
    db.commit()
    db.close()
    return jsonify({"success": True, "message": "用户已删除"})

@app.route("/api/admin/user/<user_id>/reset-password", methods=["POST"])
@require_admin
def admin_reset_password(user_id):
    data = request.get_json() or {}
    password = data.get("password", "123456")
    db = get_db()
    db.execute("UPDATE users SET password_hash=? WHERE id=?", (hash_password(password), user_id))
    db.commit()
    db.close()
    return jsonify({"success": True, "message": "密码已重置"})

# ── OCR 识别 ─────────────────────────────────────────
def baidu_ocr_access_token():
    """获取百度 OCR access token"""
    if not BAIDU_API_KEY or not BAIDU_SECRET_KEY:
        print("  [OCR] 错误: API Key 未配置")
        return None
    url = "https://aip.baidubce.com/oauth/2.0/token"
    params = {
        "grant_type": "client_credentials",
        "client_id": BAIDU_API_KEY,
        "client_secret": BAIDU_SECRET_KEY
    }
    try:
        resp = requests.get(url, params=params, timeout=10)
        if resp.status_code == 200:
            token = resp.json().get("access_token")
            print(f"  [OCR] Token 获取成功")
            return token
        else:
            print(f"  [OCR] Token 获取失败: HTTP {resp.status_code} - {resp.text[:200]}")
            return None
    except Exception as e:
        print(f"  [OCR] Token 获取异常: {e}")
        return None

def call_baidu_ocr(image_base64, ocr_type="vat_invoice"):
    """调用百度OCR"""
    token = baidu_ocr_access_token()
    if not token:
        return None, "百度OCR Access Token获取失败"
    
    url = f"https://aip.baidubce.com/rest/2.0/ocr/v1/{ocr_type}"
    params = {"access_token": token}
    data = {"image": image_base64}
    
    resp = requests.post(url, params=params, data=data)
    if resp.status_code != 200:
        return None, f"OCR HTTP {resp.status_code}"
    
    result = resp.json()
    if "error_code" in result:
        return None, f"百度OCR错误: {result.get('error_msg', '未知')}"
    
    return result, None

def extract_pdf_text(filepath):
    """从PDF提取文字（基本提取，用python库）"""
    try:
        import pdfplumber
        with pdfplumber.open(str(filepath)) as pdf:
            text = ""
            for page in pdf.pages[:5]:
                t = page.extract_text() or ""
                text += t + "\n"
            text = text.strip()
            if len(text) > 5:
                # CID编码检测：如果包含(cid:，说明是编码字体，文字无法正常提取
                if text.count("(cid:") > 3:
                    return None  # 触发前端使用图片识别
                return text
            return None
    except ImportError:
        return None
    except Exception:
        return None


def auto_categorize(db, invoice_id, seller_name, item_desc, project_location):
    """自动识别费用类目和地点（对标 Supabase Edge Function）"""
    s = (seller_name or "").lower()
    i = (item_desc or "").lower()
    
    # 从商家名称中检测城市
    seller_city = detect_city(seller_name)
    desc_city = detect_city(item_desc)
    city = seller_city or desc_city or project_location
    
    # 确定是否为出差（非广州）
    is_out_of_town = city and city != "广州"
    
    cat_name = None
    
    # 交通类
    if any(kw in i for kw in ["铁路", "高铁", "航空", "机票", "火车"]) or any(kw in s for kw in ["航空", "铁路"]):
        cat_name = "出差交通费"
    # 加油类
    elif any(kw in s for kw in ["油", "石油", "石化", "加油站"]):
        cat_name = "出差交通费"
    # 住宿类（必须在餐饮类之前，避免"酒店"被"酒"误匹配）
    elif any(kw in s for kw in ["酒店", "宾馆", "住宿", "旅店", "民宿"]):
        cat_name = "出差住房费"
    # 餐饮类
    elif any(kw in s for kw in ["餐饮", "餐厅", "饭", "酒", "茶", "咖啡", "烘焙", "面包", "甜品"]):
        if any(kw in i for kw in ["客情", "招待", "客户"]):
            cat_name = "客情餐饮费"
        else:
            cat_name = "出差餐饮费" if is_out_of_town else "日常餐饮费"
    # 通讯类
    elif any(kw in s for kw in ["通讯", "通信", "移动", "联通", "电信"]):
        cat_name = "通讯费"
    # 办公用品
    elif any(kw in s for kw in ["文具", "办公", "打印", "墨盒", "纸张"]):
        cat_name = "办公用品"
    
    updates = {}
    if city and (not project_location or project_location.strip() == ""):
        updates["project_location"] = city
    
    if cat_name:
        row = db.execute("SELECT id FROM expense_categories WHERE name=?", (cat_name,)).fetchone()
        if row:
            updates["category_id"] = row["id"]
    
    if updates:
        set_clauses = ", ".join(f"{k}=?" for k in updates.keys())
        values = list(updates.values()) + [invoice_id]
        db.execute(f"UPDATE invoices SET {set_clauses} WHERE id=?", values)
        db.commit()
        print(f"  [分类] 自动设置: {updates}")
    
    return updates


def parse_ocr_result(ocr_data):
    """解析OCR返回的结构化数据"""
    result = {}
    if not ocr_data:
        return result
    
    # 兼容不同格式：dict / 字符串
    if isinstance(ocr_data, str):
        text = ocr_data
    else:
        raw = ocr_data.get("words_result", [])
        if isinstance(raw, dict):
            # 增值税发票接口返回 dict，直接拼接所有文本
            parts = []
            for v in raw.values():
                if isinstance(v, dict): parts.append(v.get("words", ""))
                elif isinstance(v, str): parts.append(v)
            text = " ".join(parts)
        else:
            # 通用文字识别返回 list
            text = " ".join(w.get("words", "") for w in raw) if raw else ""
    text = re.sub(r"\s+", "", text)
    
    # 发票号码
    m = re.search(r"(?:发票|号码|票号)\s*[：:]*\s*(\d{8,25})", text)
    if m: result["invoice_number"] = m.group(1)
    # 备用：直接匹配8位以上纯数字（增值税发票格式）
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
    
    # 总金额
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
    for prefix in ["销售方", "收款方", "商户名称"]:
        idx = text.find(prefix)
        if idx >= 0:
            chunk = text[idx:idx+50]
            m = re.search(r"名称\s*[：:]*\s*([^\s\n]{2,30})", chunk)
            if m:
                result["seller_name"] = m.group(1).strip()
                break
            m = re.search(r"(?:[\u4e00-\u9fff]{2,10}(?:有限公司|经营部|商行|店|餐厅))", chunk)
            if m:
                result["seller_name"] = m.group(0)
                break
    
    # 地点
    loc = detect_city(text)
    if loc:
        result["project_location"] = loc
    
    return result

@app.route("/api/ocr", methods=["POST"])
@require_auth
def ocr_process():
    data = request.get_json() or {}
    invoice_id = data.get("invoice_id")
    storage_path = data.get("storage_path")
    image_base64 = data.get("image_base64")
    
    if not invoice_id:
        return jsonify({"success": False, "error": "缺少 invoice_id"}), 400
    
    db = get_db()
    
    # 尝试PDF文字提取
    if storage_path and not image_base64:
        filepath = INVOICES_DIR / storage_path
        if filepath.exists():
            text = extract_pdf_text(filepath)
            if text:
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
                db.execute("""
                    UPDATE invoices SET invoice_number=?, invoice_date=?, seller_name=?,
                    total_amount=?, project_location=?, raw_ocr_text=?, status='pending'
                    WHERE id=?
                """, (updates["invoice_number"], updates["invoice_date"], updates["seller_name"],
                      updates["total_amount"], updates["project_location"], updates["raw_ocr_text"], invoice_id))
                db.commit()
                print(f"  [OCR] PDF提取: {updates}")
                # 自动分类
                auto_categorize(db, invoice_id, updates.get("seller_name", ""), "", updates.get("project_location", ""))
                db.close()
                return jsonify({"success": True, "data": updates})
            else:
                db.close()
                return jsonify({"success": False, "error": "无法提取PDF文字，请使用图片识别", "need_image": True})
    
    if image_base64:
        print(f"  [OCR] 收到图片数据 ({len(image_base64)} 字符)，开始调用百度OCR")
        ocr_data, err = call_baidu_ocr(image_base64, "vat_invoice")
        if err or not ocr_data:
            print(f"  [OCR] 增值税发票识别失败: {err}，降级到通用文字识别")
            ocr_data, err = call_baidu_ocr(image_base64, "general")
        
        if ocr_data and not err:
            print(f"  [OCR] 识别成功")
            try:
                parsed = parse_ocr_result(ocr_data)
            except Exception as pe:
                print(f"  [OCR] 解析失败: {pe}")
                parsed = {}
            
            # 无论能否解析结构化数据，都保存识别结果
            updates = {
                "invoice_number": parsed.get("invoice_number", "") if parsed else "",
                "invoice_date": parsed.get("invoice_date", "") if parsed else "",
                "seller_name": parsed.get("seller_name", "") if parsed else "",
                "total_amount": parsed.get("total_amount", 0) if parsed else 0,
                "project_location": parsed.get("project_location", "") if parsed else "",
            }
            
            # 保存原始OCR文本
            try:
                if isinstance(ocr_data, dict):
                    raw_words = ocr_data.get("words_result", [])
                    if isinstance(raw_words, dict):
                        raw_text = " ".join(v.get("words","") if isinstance(v,dict) else str(v) for v in raw_words.values())
                    elif isinstance(raw_words, list):
                        raw_text = " ".join(w.get("words","") for w in raw_words)
                    else:
                        raw_text = str(ocr_data)
                else:
                    raw_text = str(ocr_data)
            except:
                raw_text = ""
            
            updates["raw_ocr_text"] = raw_text[:500]
            
            db.execute("""
                UPDATE invoices SET invoice_number=?, invoice_date=?, seller_name=?,
                total_amount=?, project_location=?, raw_ocr_text=?, updated_at=datetime('now','localtime')
                WHERE id=?
            """, (updates["invoice_number"], updates["invoice_date"], updates["seller_name"],
                  updates["total_amount"], updates["project_location"], updates["raw_ocr_text"], invoice_id))
            db.commit()
            print(f"  [OCR] 保存: 编号={updates['invoice_number']}, 商家={updates['seller_name']}, 金额={updates['total_amount']}")
            # 自动分类
            auto_categorize(db, invoice_id, updates.get("seller_name", ""), updates.get("item_description", ""), updates.get("project_location", ""))
            db.close()
            return jsonify({"success": True, "data": updates, "message": "识别完成" if parsed else "识别完成但未能提取结构化数据，请手动编辑"})
    
    db.close()
    err_msg = "OCR识别失败"
    if image_base64 and not BAIDU_API_KEY:
        err_msg = "OCR暂不可用：未配置百度云API Key"
    elif image_base64 and err:
        err_msg = f"OCR识别失败: {err}"
    print(f"  [OCR] 失败: {err_msg}")
    return jsonify({"success": False, "error": err_msg})

# ── 清理重复发票 ──────────────────────────────────────
@app.route("/api/invoices/cleanup", methods=["POST"])
@require_auth
def cleanup_duplicates():
    """清理重复发票（同名+同大小视为重复，保留最新）"""
    db = get_db()
    uid = current_user_id()
    
    if is_admin():
        all_invs = db.execute(
            "SELECT id, original_filename, file_size, storage_path FROM invoices ORDER BY created_at DESC"
        ).fetchall()
    else:
        all_invs = db.execute(
            "SELECT id, original_filename, file_size, storage_path FROM invoices WHERE uploaded_by=? ORDER BY created_at DESC",
            (uid,)
        ).fetchall()
    
    seen = {}
    to_delete_ids = []
    to_delete_paths = []
    
    for inv in all_invs:
        key = f"{inv['original_filename']}_{inv['file_size'] or 0}"
        if key in seen:
            to_delete_ids.append(inv['id'])
            to_delete_paths.append(inv['storage_path'])
        else:
            seen[key] = True
    
    if not to_delete_ids:
        db.close()
        return jsonify({"success": True, "deleted": 0, "message": "没有发现重复发票"})
    
    # 批量删除
    deleted = 0
    for inv_id in to_delete_ids:
        try:
            db.execute("DELETE FROM invoices WHERE id=?", (inv_id,))
            deleted += 1
        except Exception as e:
            print(f"  [清理] 删除失败 id={inv_id}: {e}")
    
    db.commit()
    db.close()
    
    # 删除存储文件（后台清理，不阻塞响应）
    for path in to_delete_paths:
        try:
            filepath = INVOICES_DIR / path
            if filepath.exists():
                filepath.unlink()
        except Exception as e:
            print(f"  [清理] 文件删除失败 {path}: {e}")
    
    print(f"  [清理] 已删除 {deleted} 条重复记录")
    return jsonify({"success": True, "deleted": deleted, "message": f"已清理 {deleted} 条重复记录"})

# ── 管理员统计 ────────────────────────────────────────
@app.route("/api/admin/stats", methods=["GET"])
@require_admin
def admin_stats():
    """获取各用户费用统计"""
    db = get_db()
    current_year = datetime.now().year
    
    stats = db.execute("""
        SELECT u.id, u.email, u.name,
            COUNT(i.id) as total_count,
            SUM(CASE WHEN i.status='approved' THEN 1 ELSE 0 END) as approved_count,
            COALESCE(SUM(i.total_amount), 0) as total_amount,
            COALESCE(SUM(CASE WHEN i.status='approved' THEN i.total_amount ELSE 0 END), 0) as approved_amount
        FROM users u
        LEFT JOIN invoices i ON i.uploaded_by = u.id 
            AND i.invoice_date >= ? AND i.invoice_date <= ?
        GROUP BY u.id, u.email, u.name
        ORDER BY total_amount DESC
    """, (f"{current_year}-01-01", f"{current_year}-12-31")).fetchall()
    
    db.close()
    return jsonify({
        "year": current_year,
        "stats": [dict(row) for row in stats]
    })

# ── 删除费用类目 ──────────────────────────────────────
@app.route("/api/categories/<int:cat_id>", methods=["DELETE"])
@require_admin
def delete_category(cat_id):
    """删除费用类目（仅管理员，且该类别下无发票时才能删除）"""
    db = get_db()
    # 检查是否有发票使用此类别
    has_invoices = db.execute("SELECT COUNT(*) as cnt FROM invoices WHERE category_id=?", (cat_id,)).fetchone()
    if has_invoices and has_invoices["cnt"] > 0:
        db.close()
        return jsonify({"error": f"该类别下有 {has_invoices['cnt']} 张发票，无法删除"}), 400
    
    db.execute("DELETE FROM expense_categories WHERE id=?", (cat_id,))
    db.commit()
    db.close()
    print(f"  [类目] 已删除 id={cat_id}")
    return jsonify({"success": True, "message": "类目已删除"})

# ── 批量更新发票状态 ──────────────────────────────────
@app.route("/api/invoices/batch-status", methods=["POST"])
@require_auth
def batch_update_status():
    """批量审核发票"""
    data = request.get_json() or {}
    ids = data.get("ids", [])
    status = data.get("status", "approved")
    
    if not ids:
        return jsonify({"error": "请选择至少一张发票"}), 400
    if status not in ("approved", "rejected"):
        return jsonify({"error": "无效的状态"}), 400
    
    db = get_db()
    updated = 0
    for inv_id in ids:
        try:
            db.execute("UPDATE invoices SET status=?, updated_at=datetime('now','localtime') WHERE id=?", (status, inv_id))
            updated += 1
        except Exception as e:
            print(f"  [批量] 更新失败 id={inv_id}: {e}")
    
    db.commit()
    db.close()
    print(f"  [批量] 已更新 {updated} 张发票状态为 {status}")
    return jsonify({"success": True, "updated": updated})

# ── 启动 ──────────────────────────────────────────────
if __name__ == "__main__":
    print("═" * 40)
    print("  ECS 报销管理系统 (自托管版)")
    print("═" * 40)
    init_db()
    print(f"\n  ➜ 启动地址: http://0.0.0.0:{PORT}")
    print(f"  ➜ 管理员: {ADMIN_EMAIL}")
    print(f"  ➜ 百度OCR: {'已配置' if BAIDU_API_KEY else '未配置（手动录入可用）'}")
    print(f"═" * 40)
    app.run(host="0.0.0.0", port=PORT, debug=False)
