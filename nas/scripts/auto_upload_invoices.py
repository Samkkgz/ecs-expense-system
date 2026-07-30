#!/usr/bin/env python3
"""
auto_upload_invoices.py — ECS 发票自动上传监听脚本（纯内置模块，零依赖）

监听 "ECS Expenses/" 目录及子目录，检测到新发票文件（PDF/PNG/JPG）后，
自动上传到 NAS 上已部署的 ECS 系统（Supabase Storage + PostgREST RPC）。
月份由系统 OCR 服务后续自动识别纠正，本脚本不绑定目录结构。

使用方式：
    python3 nas/scripts/auto_upload_invoices.py                  # 前台运行
    python3 nas/scripts/auto_upload_invoices.py --daemon         # 后台运行
    kill `cat /tmp/auto_upload_invoices.pid`                     # 停止

设计原则：
    - 零外部依赖（仅用 Python 内置模块）
    - 本地文件轮询（非网络轮询，M4 上 ≈ 0% CPU）
    - 对 NAS 已部署系统零改动（复用现有 SERVICE_KEY 认证）
    - 支持文件新增、内容修改自动检测和重新上传
"""

import os
import sys
import json
import time
import hashlib
import sqlite3
import logging
import argparse
import atexit
import threading
from datetime import datetime

# 进程级处理锁 — 防止同一文件被多个扫描周期重复处理
_processing_files = set()
_processing_lock = threading.Lock()
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


# ============================================================
# 配置区
# ============================================================

DEFAULT_WATCH_DIR = os.path.expanduser(
    "~/Documents/Business Related/Finance/Expenses/ECS  Expenses"
)

# NAS API 地址（ECS 系统 Nginx 网关）
# 默认使用 Tailscale 内网地址访问 NAS（稳定可靠，不受 Cloudflare WAF 影响）
# 若要通过 Cloudflare Tunnel 访问，设置环境变量：
#   export ECS_NAS_HOST="http://100.105.75.56:18000"
NAS_HOST = os.environ.get("ECS_NAS_HOST", "http://100.105.75.56:18000")
# 通过环境变量切换回 Tailscale 内网地址：
#   export ECS_NAS_HOST="http://100.105.75.56:18000"
STORAGE_API = f"{NAS_HOST}/storage/v1/object/invoices"
REST_API = f"{NAS_HOST}/rest/v1/rpc/insert_invoice"

# 认证凭据 — 复用 docker-compose.yml 中已有的 SERVICE_KEY（service_role JWT）
# 已在 OCR 容器中使用，不改动现有任何配置
SERVICE_KEY = (
    "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
    ".eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODE0MjU0NzAsImV4cCI6MjA5Njc4NTQ3MH0"
    ".6G3AYHeOucFMTIPnsFn4558OBy9x4mbD3_dT0VBGHJs"
)

# 浏览器 User-Agent，绕过 Cloudflare 的 Browser Integrity Check
_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

def _headers(extra=None):
    """返回包含浏览器 UA 的请求头字典，合并 extra 中的字段"""
    h = {"User-Agent": _USER_AGENT, "Accept": "*/*"}
    if extra:
        h.update(extra)
    return h

PID_FILE = "/tmp/auto_upload_invoices.pid"
LOG_FILE = "/tmp/auto_upload_invoices.log"
SCAN_INTERVAL = 5            # 扫描间隔（秒）
STABLE_INTERVAL = 1.0        # 文件稳定性检测间隔
STABLE_COUNT = 3             # 连续稳定才算写完
UPLOAD_TIMEOUT = 120         # 上传超时（秒）

# ======== 稳定机制 v4.8 新增配置 ========
FAILED_RETRY_INTERVAL = 1800    # _failed/ 重试间隔（秒）= 30分钟
NAS_CHECK_INTERVAL = 60         # NAS 连通性检查间隔（秒）
BACKOFF_BASE = 30               # 初始退避秒数（网络断连时）
BACKOFF_MAX = 600               # 最大退避秒数（10分钟）
_nas_down_since = 0.0           # NAS 断开时间戳
_last_failed_retry = 0          # 上次重试 _failed/ 的循环计数


# 支持的发票文件扩展名
SUPPORTED_EXTS = {".pdf", ".png", ".jpg", ".jpeg", ".bmp"}


# ============================================================
# 日志
# ============================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ],
)
log = logging.getLogger("auto_upload_invoices")


# ============================================================
# 去重数据库
# ============================================================

def _db_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "_upload_log.db")


def init_db(db_path=None):
    """初始化去重数据库。

    记录维度：
      - file_path: 文件相对路径
      - file_hash: SHA256 哈希（检测内容变化）
      - file_size: 文件大小
      - modified_at: 文件最后修改时间
    新增 v2：hash_index 用于全局哈希查重（跨路径检测同一文件）
    """
    path = db_path or _db_path()
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS uploads ("
        "  file_path TEXT PRIMARY KEY,"
        "  file_hash TEXT NOT NULL,"
        "  file_size INTEGER DEFAULT 0,"
        "  modified_at REAL DEFAULT 0,"
        "  uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP"
        ")"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_uploads_hash ON uploads(file_hash)"
    )
    conn.commit()
    return conn


def get_record(conn, rel_path):
    """查询文件的历史上传记录（按相对路径）"""
    cur = conn.execute(
        "SELECT file_hash, file_size, modified_at FROM uploads WHERE file_path = ?",
        (rel_path,),
    )
    return cur.fetchone()


def find_by_hash(conn, file_hash):
    """按 SHA256 哈希查找是否已有上传记录（跨路径检测同一文件）
    
    即使文件路径不同，只要内容相同（同一发票的两个副本）也能检测到。
    """
    cur = conn.execute(
        "SELECT file_path, file_size, modified_at FROM uploads WHERE file_hash = ? LIMIT 1",
        (file_hash,),
    )
    return cur.fetchone()


def upsert_record(conn, rel_path, file_hash, file_size, modified_at):
    """插入或更新文件的上传记录"""
    conn.execute(
        "INSERT OR REPLACE INTO uploads (file_path, file_hash, file_size, modified_at) "
        "VALUES (?, ?, ?, ?)",
        (rel_path, file_hash, file_size, modified_at),
    )
    conn.commit()


# ============================================================
# 文件工具
# ============================================================

def compute_hash(filepath):
    """计算文件 SHA256 哈希"""
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def wait_file_stable(filepath):
    """等待文件写入完成（大小连续稳定）"""
    last_size = -1
    stable_checks = 0
    for _ in range(30):
        try:
            cur_size = os.path.getsize(filepath)
        except OSError:
            return False
        if cur_size == last_size and cur_size > 0:
            stable_checks += 1
            if stable_checks >= STABLE_COUNT:
                return True
        else:
            stable_checks = 0
        last_size = cur_size
        time.sleep(STABLE_INTERVAL)
    return False


def move_file(src, dest_dir):
    """将文件移至目标目录，保留相对路径结构。源文件不存在时静默忽略。"""
    abs_watch = os.path.abspath(DEFAULT_WATCH_DIR)
    rel = os.path.relpath(src, abs_watch)
    dest = os.path.join(dest_dir, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        os.rename(src, dest)
    except FileNotFoundError:
        log.warning(f"⚠ 文件不存在，跳过移动: {src}")
        return None
    except OSError as e:
        log.warning(f"⚠ 文件移动失败: {src} → {e}")
        return None
    return dest


def is_supported_file(filename):
    """判断是否为受支持的发票文件（排除 Office 临时锁定文件）"""
    if filename.startswith("~$"):
        return False
    if filename.startswith("."):
        return False
    ext = os.path.splitext(filename)[1].lower()
    return ext in SUPPORTED_EXTS


# ============================================================
# NAS API 调用
# ============================================================

# 浏览器类 User-Agent，绕过 Cloudflare Browser Integrity Check
def _mime_type(path):
    """根据文件扩展名返回正确的 MIME 类型"""
    ext = os.path.splitext(path)[1].lower()
    return {
        ".pdf": "application/pdf",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".bmp": "image/bmp",
    }.get(ext, "application/octet-stream")


def nas_upload_file(local_path, storage_path):
    """上传文件到 NAS Supabase Storage。
    
    POST /storage/v1/object/invoices/{storage_path}
    与前端 Supabase JS 客户端 upload() 方法等效。
    使用正确的 MIME 类型确保浏览器可内联渲染。
    """
    url = f"{STORAGE_API}/{storage_path}"
    with open(local_path, "rb") as f:
        file_data = f.read()

    content_type = _mime_type(storage_path)
    headers = _headers({
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": content_type,
    })
    req = Request(url, data=file_data, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=UPLOAD_TIMEOUT) as resp:
            raw = resp.read()
            log.debug(f"[Storage] POST {url} → {resp.status}")
            result = json.loads(raw) if raw else {}
            if resp.status == 200:
                return True, result
            return True, result
    except HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")[:300]
        log.error(f"[Storage] HTTP {e.code}: {err_body}")
        return False, f"HTTP {e.code}: {err_body}"
    except Exception as e:
        log.error(f"[Storage] 请求异常: {e}")
        return False, str(e)


def nas_insert_invoice(storage_path, original_filename, file_size, invoice_date):
    """调用 PostgREST RPC 插入发票数据库记录。
    
    POST /rest/v1/rpc/insert_invoice
    与前端 sb.rpc('insert_invoice', body) 等效。
    """
    body = {
        "p_storage_path": storage_path,
        "p_original_filename": original_filename,
        "p_file_size": file_size,
        "p_invoice_date": invoice_date,
    }
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = _headers({
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
    })
    req = Request(REST_API, data=data, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=UPLOAD_TIMEOUT) as resp:
            raw = resp.read()
            log.debug(f"[RPC] POST insert_invoice → {resp.status}")
            result = json.loads(raw) if raw else {}
            return True, result
    except HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")[:300]
        log.error(f"[RPC] HTTP {e.code}: {err_body}")
        return False, f"HTTP {e.code}: {err_body}"
    except Exception as e:
        log.error(f"[RPC] 请求异常: {e}")
        return False, str(e)


# ============================================================
# 文件处理
# ============================================================

def check_nas_duplicate(original_filename, file_size):
    """查询 NAS 数据库，检查是否已有相同文件名+大小的记录。
    
    GET /rest/v1/invoices?original_filename=eq.{name}&file_size=eq.{size}&select=id
    与前端上传前的 dupes 查询逻辑一致。
    """
    import urllib.parse
    params = urllib.parse.urlencode({
        "select": "id",
        "original_filename": f"eq.{original_filename}",
        "file_size": f"eq.{file_size}",
        "limit": "1",
    })
    url = f"{NAS_HOST}/rest/v1/invoices?{params}"
    headers = _headers({
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
    })
    req = Request(url, headers=headers, method="GET")
    try:
        with urlopen(req, timeout=15) as resp:
            raw = resp.read()
            result = json.loads(raw) if raw else []
            return len(result) > 0
    except Exception as e:
        log.warning(f"[查重] NAS 查询失败: {e}（跳过本次检查）")
        return False



def _remove_nas_duplicate_if_exists(conn, rel_path, filename, file_size):
    """上传后二次查重：检查是否因并发导致产生重复记录，保留最早的删除最新的。
    
    策略：先按 file_size 查询（无编码问题），再在 Python 端按文件名过滤。
    确保即使文件名包含特殊字符（中文、括号、空格等）也能准确查重。
    这是最终兜底防线。
    
    Returns: True 如果发现了重复并清理，False 如果没有重复
    """
    headers = _headers({
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
    })
    
    # 按 file_size 查询 + id 排序（避免文件名 URL 编码问题）
    url = f"{NAS_HOST}/rest/v1/invoices?select=id,original_filename,file_size,storage_path,created_at&file_size=eq.{file_size}&order=id.asc"
    req = Request(url, headers=headers, method="GET")
    
    try:
        with urlopen(req, timeout=15) as resp:
            all_with_size = json.loads(resp.read())
        
        # 在 Python 端精确匹配文件名
        records = [r for r in all_with_size if r.get("original_filename", "") == filename]
        
        if len(records) <= 1:
            return False  # 没有重复
        
        # 保留第一条（最老的），删除后续的
        keep = records[0]
        deleted = 0
        for dup in records[1:]:
            dup_id = dup.get("id")
            dup_storage = dup.get("storage_path", "")
            
            # 删除数据库记录
            del_url = f"{NAS_HOST}/rest/v1/invoices?id=eq.{dup_id}"
            del_req = Request(del_url, headers=headers, method="DELETE")
            with urlopen(del_req, timeout=15):
                pass
            
            log.info(f"    🗑 二次查重清理: ID {dup_id} ({dup_storage})")
            deleted += 1
            
            # 也删除对应的 storage 文件（如果有且不同路径）
            if dup_storage and dup_storage != keep.get("storage_path", ""):
                try:
                    storage_url = f"{STORAGE_API}/{dup_storage}"
                    del_storage_req = Request(storage_url, headers=headers, method="DELETE")
                    with urlopen(del_storage_req, timeout=15):
                        pass
                    log.info(f"      🗑 清理 Storage: {dup_storage}")
                except Exception:
                    pass  # 忽略 storage 删除失败
        
        log.info(f"✅ 二次查重完成: 保留 ID {keep.get('id')}, 清理 {deleted} 条重复")
        return True
    except Exception as e:
        log.warning(f"[二次查重] 查询/清理失败: {e}")
        return False


def cleanup_nas_duplicates(dry_run=True):
    """检测并清理 NAS 数据库中重复的发票记录。
    
    重复判定：相同 original_filename + file_size
    策略：保留最早创建的记录，删除后续重复记录（只清理数据库，不操作本地文件）。
    
    Args:
        dry_run: True 仅显示，False 实际删除
    Returns:
        (found_count, deleted_count)
    """
    headers = _headers({
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
    })
    
    # 查询所有记录，按文件名+大小分组找重复
    base_url = f"{NAS_HOST}/rest/v1/invoices"
    
    # 第1步：获取 count 按 filename+size 分组的重复项
    import urllib.parse
    params = urllib.parse.urlencode({
        "select": "id,original_filename,file_size,created_at,invoice_date,total_amount,storage_path",
        "order": "original_filename.asc",
    })
    url = f"{base_url}?{params}"
    req = Request(url, headers=headers, method="GET")
    try:
        with urlopen(req, timeout=30) as resp:
            all_records = json.loads(resp.read())
    except Exception as e:
        log.error(f"[清理] 查询发票列表失败: {e}")
        return 0, 0
    
    # 按 (filename, size) 分组
    groups = {}
    for r in all_records:
        key = (r.get("original_filename", ""), r.get("file_size", 0))
        groups.setdefault(key, []).append(r)
    
    # 找出有重复的分组
    dup_groups = {k: v for k, v in groups.items() if len(v) > 1}
    
    if not dup_groups:
        log.info("[清理] ✅ 未发现重复记录")
        return 0, 0
    
    log.info(f"[清理] 发现 {len(dup_groups)} 组重复，共涉及 {sum(len(v) for v in dup_groups)} 条记录:")
    for (fname, fsize), records in dup_groups.items():
        log.info(f"  📄 {fname} ({fsize} bytes) × {len(records)} 条")
        for r in records:
            log.info(f"      ID: {r.get('id')} | 日期: {r.get('invoice_date','-')} | 金额: {r.get('total_amount','-')}")
    
    if dry_run:
        log.info(f"[清理] ⚠ 预览模式，未实际删除。使用 --cleanup 执行删除。")
        return len(dup_groups), 0
    
    # 非 dry_run：执行删除
    deleted = 0
    for (fname, fsize), records in dup_groups.items():
        # 按 created_at 排序，保留最早的
        records_sorted = sorted(records, key=lambda r: r.get("created_at", ""))
        keep = records_sorted[0]
        to_delete = records_sorted[1:]
        
        for rec in to_delete:
            rec_id = rec.get("id")
            storage_path = rec.get("storage_path", "")
            
            # 删除数据库记录
            del_url = f"{base_url}?id=eq.{rec_id}"
            del_req = Request(del_url, headers=headers, method="DELETE")
            try:
                with urlopen(del_req, timeout=15) as resp:
                    log.info(f"    🗑 删除记录: {fname} (ID: {rec_id})")
                
                # 只清理数据库记录，不操作本地文件
                deleted += 1
            except Exception as e:
                log.warning(f"    ⚠ 删除失败 (ID: {rec_id}): {e}")
    
    log.info(f"[清理] ✅ 完成: 清理 {deleted} 条重复记录")
    return len(dup_groups), deleted

def backfill_from_nas(watch_dir, conn):
    """回填模式：将本地文件与 NAS 数据库比对，标记已有记录为已上传。
    
    使用方式: python3 auto_upload_invoices.py --backfill
    适用于首次启动、去重库丢失、批量导入后同步状态。
    """
    abs_watch = os.path.abspath(watch_dir)
    checked = 0
    matched = 0
    for root, dirs, files in os.walk(abs_watch):
        # 回填模式不过滤 _imported（需标记已上传的记录）
        dirs[:] = [d for d in dirs if not d.startswith(".") and (not d.startswith("_") or d == "_imported")]
        for fname in files:
            if not is_supported_file(fname):
                continue
            fpath = os.path.join(root, fname)
            if not os.path.isfile(fpath):
                continue
            rel_path = os.path.relpath(fpath, abs_watch)
            file_size = os.path.getsize(fpath)
            modified_at = os.path.getmtime(fpath)
            checked += 1
            
            # 查 NAS 数据库
            if check_nas_duplicate(fname, file_size):
                file_hash = compute_hash(fpath)
                upsert_record(conn, rel_path, file_hash, file_size, modified_at)
                matched += 1
                log.info(f"  📌 已有记录: {rel_path}")
    
    log.info(f"回填完成: 检查 {checked} 个文件，{matched} 个已有记录")
    return checked, matched


def process_file(filepath, conn):
    """处理单个发票文件：去重检测 → 上传 Storage → 插入数据库记录"""
    abs_watch = os.path.abspath(DEFAULT_WATCH_DIR)
    rel_path = os.path.relpath(filepath, abs_watch)
    
    # ======== 进程级处理锁 ========
    with _processing_lock:
        if rel_path in _processing_files:
            log.info(f"⏭ 跳过（已在处理中）: {rel_path}")
            return
        _processing_files.add(rel_path)
    
    try:
        _process_file_inner(filepath, conn, abs_watch, rel_path)
    finally:
        with _processing_lock:
            _processing_files.discard(rel_path)


def _process_file_inner(filepath, conn, abs_watch, rel_path):
    """process_file 的内部实现，由 process_file 包装处理锁后调用"""
    file_size = os.path.getsize(filepath)
    modified_at = os.path.getmtime(filepath)

    # 快速预检：大小+修改时间完全匹配 → 跳过（需二次核对NAS）
    record = get_record(conn, rel_path)
    if record is not None:
        old_hash, old_size, old_mtime = record
        if old_size == file_size and old_mtime == modified_at:
            # 核对NAS是否真有此记录（防止RPC失败后本地记录残留）
            fname = os.path.basename(filepath)
            if check_nas_duplicate(fname, file_size):
                log.debug(f"⏭ 跳过（无变化）: {rel_path}")
                # 文件已在 NAS 中，移至 _imported/
                dest3 = move_file(filepath, os.path.join(abs_watch, "_imported"))
                if dest3:
                    log.info(f"📦 移至 _imported（NAS 已有记录）: {rel_path}")
                return
            else:
                log.info(f"🔄 本地记录但NAS无记录，重新上传: {rel_path}")

    # 等待文件稳定（写入完成）
    log.info(f"⏳ 等待文件稳定: {rel_path}")
    if not wait_file_stable(filepath):
        log.warning(f"⚠ 文件未能稳定: {rel_path}，跳过本轮")
        return

    # 哈希二次查重
    file_hash = compute_hash(filepath)
    
    # ======== 哈希去重：先查本地，再核对 NAS ========
    hash_record = find_by_hash(conn, file_hash)
    if hash_record is not None:
        # 哈希匹配本地记录，但还需检查 NAS 是否仍有记录
        # 场景：用户从管理页面删除了发票（NAS 记录已清），但本地哈希还在
        # 此时应重新上传，不能跳过
        filename = os.path.basename(filepath)
        if check_nas_duplicate(filename, file_size):
            log.info(f"⏭ 跳过（哈希+NAS都已有记录）: {rel_path}")
            upsert_record(conn, rel_path, file_hash, file_size, modified_at)
            dest4 = move_file(filepath, os.path.join(abs_watch, "_imported"))
            if dest4:
                log.info(f"📦 移至 _imported: {rel_path}")
            return
        else:
            log.info(f"🔄 哈希匹配但NAS无记录，重新上传: {rel_path}")
            # 更新本地记录的时间戳，让后续流程走通
            upsert_record(conn, rel_path, file_hash, file_size, modified_at)
            # 继续执行上传流程

    if record is not None and record[0] == file_hash:
        log.debug(f"⏭ 跳过（内容未变）: {rel_path}")
        upsert_record(conn, rel_path, file_hash, file_size, modified_at)
        return

    filename = os.path.basename(filepath)

    # 查重：查询 NAS 数据库是否已有相同文件
    log.info(f"🔍 查重: {rel_path}")
    if check_nas_duplicate(filename, file_size):
        log.info(f"⏭ 跳过（NAS 已有同名同大小记录）: {rel_path}")
        upsert_record(conn, rel_path, file_hash, file_size, modified_at)
        dest5 = move_file(filepath, os.path.join(abs_watch, "_imported"))
        if dest5:
            log.info(f"📦 移至 _imported: {rel_path}")
        return

    # 准备上传参数
    now = datetime.now()
    ext = os.path.splitext(filepath)[1].lower()
    timestamp_ms = int(time.time() * 1000)
    storage_path = f"{now.year}/{now.month:02d}/{timestamp_ms}{ext}"
    invoice_date = f"{now.year}-{now.month:02d}-01"

    log.info(f"📤 上传中: {rel_path}")
    log.info(f"   Storage: {storage_path}")
    log.info(f"   日期: {invoice_date}")

    # 第1步：上传文件到 Storage
    success, result = nas_upload_file(filepath, storage_path)
    if not success:
        log.error(f"❌ Storage 上传失败: {rel_path} → {result}")
        dest = move_file(filepath, os.path.join(abs_watch, "_failed"))
        if dest:
            log.info(f"  移至: {dest}")
        upsert_record(conn, rel_path, file_hash, file_size, modified_at)
        log.info(f"  （已记录哈希，避免重复上传失败）")
        return

    log.info(f"✅ Storage 上传成功: {rel_path}")

    # 第2步：插入前最终查重（sleep 200ms 让可能的并发插入完成）
    time.sleep(0.2)
    if check_nas_duplicate(filename, file_size):
        log.info(f"⏭ 跳过（最终查重命中: 另一副本已插入）: {rel_path}")
        upsert_record(conn, rel_path, file_hash, file_size, modified_at)
        dest = move_file(filepath, os.path.join(abs_watch, "_imported"))
        log.info(f"  移至: {dest}")
        return
    
    # 第3步：插入数据库记录
    log.debug(f"[RPC] 调用 insert_invoice: {storage_path}, {filename}, {file_size}")
    ok, rpc_result = nas_insert_invoice(
        storage_path, filename, file_size, invoice_date
    )
    if not ok:
        log.error(f"❌ 数据库写入失败: {rel_path} → {rpc_result}")
        dest = move_file(filepath, os.path.join(abs_watch, "_failed"))
        if dest:
            log.info(f"  文件已移至: {dest}")
        log.warning(f"  注意: Storage 文件已上传但未关联数据库，需人工处理")
        upsert_record(conn, rel_path, file_hash, file_size, modified_at)
        return

    # 成功：记录去重 + 移至 _imported
    upsert_record(conn, rel_path, file_hash, file_size, modified_at)
    dest = move_file(filepath, os.path.join(abs_watch, "_imported"))
    log.info(f"✅ 上传完成: {rel_path}")
    if dest:
        log.info(f"  移至: {dest}")



# ============================================================
# v4.8：连通性检查 & 自动重试
# ============================================================

def _check_nas_connectivity():
    """检查 NAS API 是否可达（快速健康检查）。
    
    尝试访问 NAS 的 root 端点，超时 5 秒。
    Returns: True 可达, False 不可达
    """
    url = f"{NAS_HOST}/"
    req = Request(url, method="GET", headers=_headers())
    try:
        with urlopen(req, timeout=5) as resp:
            return resp.status < 500
    except Exception:
        return False


def _get_backoff_delay():
    """根据 NAS 离线时长计算指数退避延迟。
    
    公式: min(BACKOFF_BASE * 2^n, BACKOFF_MAX)
    其中 n = 离线分钟数 // 2（每 2 分钟退避一级）
    """
    global _nas_down_since
    if _nas_down_since <= 0:
        return 0
    elapsed = time.time() - _nas_down_since
    n = int(elapsed // 120)
    delay = min(BACKOFF_BASE * (2 ** n), BACKOFF_MAX)
    return delay


def _handle_nas_disconnect():
    """NAS 不可达时的等待逻辑：
    1. 记录首次断开时间戳
    2. 计算指数退避延迟
    3. 跳过本轮上传，进入等待
    """
    global _nas_down_since
    if _nas_down_since <= 0:
        _nas_down_since = time.time()
    delay = _get_backoff_delay()
    elapsed = time.time() - _nas_down_since
    log.info(f"NAS 不可达（已下线 {elapsed:.0f} 秒），等待 {delay} 秒后再试")
    return False


def _check_nas_alive():
    """NAS 连通性检查，更新 _nas_down_since 状态。
    Returns: True 可达, False 不可达
    """
    global _nas_down_since
    if _check_nas_connectivity():
        was_down = _nas_down_since > 0
        _nas_down_since = 0.0
        if was_down:
            log.info("NAS 恢复连接")
        return True
    else:
        _handle_nas_disconnect()
        return False


def retry_failed_files(watch_dir, conn):
    """检查 _failed/ 目录并对其中文件尝试重试上传。
    
    成功上传后移到 _imported/，连续失败不做处罚（由指数退避机制控制频率）。
    """
    abs_watch = os.path.abspath(watch_dir)
    failed_dir = os.path.join(abs_watch, "_failed")
    if not os.path.isdir(failed_dir):
        return
    
    if not _check_nas_alive():
        return
    
    found = []
    for root, dirs, files in os.walk(failed_dir):
        for fname in files:
            if not is_supported_file(fname):
                continue
            fpath = os.path.join(root, fname)
            if not os.path.isfile(fpath):
                continue
            found.append(fpath)
    
    if not found:
        return
    
    log.info(f"发现 {len(found)} 个待重试的失败文件")
    for fpath in sorted(found):
        fname = os.path.basename(fpath)
        file_size = os.path.getsize(fpath)
        
        if check_nas_duplicate(fname, file_size):
            log.info(f"  跳过（NAS 已有记录）: {os.path.basename(fpath)}")
            dest = move_file(fpath, os.path.join(abs_watch, "_imported"))
            if dest:
                log.info(f"  移至 _imported: {os.path.basename(fpath)}")
            continue
        
        if not wait_file_stable(fpath):
            log.warning(f"  文件未能稳定，跳过本轮: {os.path.basename(fpath)}")
            continue
        
        log.info(f"  重试上传: {os.path.relpath(fpath, abs_watch)}")
        ext = os.path.splitext(fpath)[1].lower()
        ts = int(time.time() * 1000)
        sp = f"{datetime.now().year}/{datetime.now().month:02d}/{ts}{ext}"
        inv_date = f"{datetime.now().year}-{datetime.now().month:02d}-01"
        
        ok, result = nas_upload_file(fpath, sp)
        if not ok:
            log.warning(f"  重试失败（等待下次扫描）: {result}")
            continue
        
        ok, rpc_result = nas_insert_invoice(sp, fname, file_size, inv_date)
        if not ok:
            log.warning(f"  数据库写入失败（等待下次扫描）: {rpc_result}")
            continue
        
        dest = move_file(fpath, os.path.join(abs_watch, "_imported"))
        log.info(f"  重试成功! 移至 _imported: {os.path.basename(fpath)}")


def scan_directory(watch_dir, conn):
    """扫描目录，返回需要处理的发票文件列表"""
    abs_watch = os.path.abspath(watch_dir)
    found = []
    seen = set()  # 本周期去重: (basename, file_size)
    for root, dirs, files in os.walk(abs_watch):
        # 跳过 _imported、_failed 和隐藏目录
        dirs[:] = [d for d in dirs if not d.startswith("_") and not d.startswith(".")]
        for fname in files:
            if not is_supported_file(fname):
                continue
            fpath = os.path.join(root, fname)
            if not os.path.isfile(fpath):
                continue

            rel_path = os.path.relpath(fpath, abs_watch)
            file_size = os.path.getsize(fpath)
            modified_at = os.path.getmtime(fpath)

            # 快速预检
            record = get_record(conn, rel_path)
            if record is not None:
                _, old_size, old_mtime = record
                if old_size == file_size and old_mtime == modified_at:
                    # 本地记录匹配，但NAS可能已被用户删除（反向删除流程）
                    # 需要确认NAS仍有此记录再跳过
                    if check_nas_duplicate(fname, file_size):
                        # 文件已在 NAS 中，移至 _imported/ 保持文件夹整洁
                        dest2 = move_file(fpath, os.path.join(abs_watch, "_imported"))
                        if dest2:
                            log.info(f"📦 移至 _imported（NAS 已有记录）: {rel_path}")
                        continue
                    else:
                        log.info(f"\U0001f504 NAS无记录，重新上传: {rel_path}")
                        # 不跳过，继续加入待处理列表

            # ======== 同名同大小去重：同一文件在多个月份文件夹中的副本 ========
            dedup_key = (fname, file_size)
            if dedup_key in seen:
                log.debug(f"⏭ 跳过同名文件（已有 {fname} 待处理）: {rel_path}")
                continue
            seen.add(dedup_key)

            found.append(fpath)

    # 按修改时间排序，旧文件优先上传
    found.sort(key=lambda p: os.path.getmtime(p))
    return found


def reupload_from_imported(watch_dir, conn):
    """扫描 _imported/ 目录，重新上传不在数据库中的文件（用正确的 MIME 类型）
    
    场景：之前的上传用了错误的 Content-Type (application/octet-stream)，
    导致预览时浏览器触发下载。重新上传会用 application/pdf / image/jpeg 等正确类型。
    
    注意：不会删除原有 storage 文件（不影响已有记录查看），
    也不会创建重复数据库记录（会先查 NAS 数据库）。
    """
    abs_watch = os.path.abspath(watch_dir)
    imported_dir = os.path.join(abs_watch, "_imported")
    if not os.path.isdir(imported_dir):
        log.info("[重传] _imported 目录不存在，无需处理")
        return 0, 0
    
    log.info("[重传] 扫描 _imported/ 目录...")
    
    found = []
    for root, dirs, files in os.walk(imported_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fname in files:
            if not is_supported_file(fname):
                continue
            fpath = os.path.join(root, fname)
            if not os.path.isfile(fpath):
                continue
            
            # 查 NAS 数据库：已存在则跳过
            file_size = os.path.getsize(fpath)
            if check_nas_duplicate(fname, file_size):
                log.info(f"  ⏭ 跳过（数据库中已有记录）: {fname}")
                continue
            
            found.append(fpath)
    
    if not found:
        log.info("[重传] 没有需要重新上传的文件")
        return 0, 0
    
    log.info(f"[重传] 发现 {len(found)} 个待重新上传的文件:")
    
    uploaded = 0
    for fpath in sorted(found):
        fname = os.path.basename(fpath)
        rel_path = os.path.relpath(fpath, abs_watch)
        
        # 准备参数
        now = datetime.now()
        ext = os.path.splitext(fpath)[1].lower()
        timestamp_ms = int(time.time() * 1000)
        storage_path = f"{now.year}/{now.month:02d}/{timestamp_ms}{ext}"
        invoice_date = f"{now.year}-{now.month:02d}-01"
        file_size = os.path.getsize(fpath)
        
        log.info(f"  📤 重传: {rel_path}")
        log.info(f"      Storage: {storage_path}")
        log.info(f"      MIME: {_mime_type(storage_path)}")
        
        # 上传到 Storage
        ok, result = nas_upload_file(fpath, storage_path)
        if not ok:
            log.error(f"      ❌ Storage 上传失败: {result}")
            continue
        
        # 插入数据库记录
        ok, rpc_result = nas_insert_invoice(storage_path, fname, file_size, invoice_date)
        if not ok:
            log.error(f"      ❌ 数据库写入失败: {rpc_result}")
            continue
        
        # 记录到本地去重库
        modified_at = os.path.getmtime(fpath)
        file_hash = compute_hash(fpath)
        upsert_record(conn, rel_path, file_hash, file_size, modified_at)
        
        uploaded += 1
        log.info(f"      ✅ 完成")
    
    log.info(f"[重传] 完成: 上传 {uploaded}/{len(found)} 个文件（正确 MIME 类型）")
    return len(found), uploaded



# ============================================================
# 主入口
# ============================================================

def cleanup():
    if os.path.exists(PID_FILE):
        os.remove(PID_FILE)


def main():
    parser = argparse.ArgumentParser(
        description="ECS 发票自动上传监听脚本 — 检测新发票并上传至 NAS"
    )
    parser.add_argument(
        "--watch",
        default=DEFAULT_WATCH_DIR,
        help=f"监听目录（默认: {DEFAULT_WATCH_DIR}）",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=SCAN_INTERVAL,
        help=f"扫描间隔秒数（默认: {SCAN_INTERVAL}）",
    )
    parser.add_argument(
        "--daemon",
        action="store_true",
        help="后台运行模式",
    )
    parser.add_argument(
        "--backfill",
        action="store_true",
        help="回填模式：比对 NAS 数据库，标记已有文件",
    )
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="清理 NAS 数据库中重复的发票记录（保留最早的）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="配合 --cleanup 使用：仅预览不实际删除",
    )
    parser.add_argument(
        "--reupload",
        action="store_true",
        help="重新上传 _imported/ 中不在数据库里的文件（用正确 MIME 类型）",
    )
    args = parser.parse_args()

    watch_dir = os.path.abspath(os.path.expanduser(args.watch))

    if not os.path.isdir(watch_dir):
        log.error(f"监听目录不存在: {watch_dir}")
        print(f"\n使用 --watch 指定其他路径：")
        print(f"  python3 nas/scripts/auto_upload_invoices.py --watch /你的/路径")
        sys.exit(1)

    # 后台模式
    if args.daemon:
        # 第一次 fork：脱离控制终端
        pid = os.fork()
        if pid > 0:
            print(f"✅ ECS 发票自动上传已启动 (PID: {pid})")
            print(f"   日志: {LOG_FILE}")
            print(f"   停止: kill {pid}")
            sys.exit(0)
        # 脱离父进程会话
        os.setsid()
        # 第二次 fork：彻底脱离终端控制
        pid = os.fork()
        if pid > 0:
            os._exit(0)
        # 重定向标准流
        sys.stdout.flush()
        sys.stderr.flush()
        with open(os.devnull, 'rb') as devnull:
            os.dup2(devnull.fileno(), sys.stdin.fileno())
        # 重新打开日志文件作为 stdout/stderr
        log_file_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
        os.dup2(log_file_fd, sys.stdout.fileno())
        os.dup2(log_file_fd, sys.stderr.fileno())
        os.close(log_file_fd)
        sys.stdout = open(LOG_FILE, "a")
        sys.stderr = open(LOG_FILE, "a")
        # 重配日志：移除控制台 Handler（FileHandler 也是 StreamHandler 子类，需排除）
        for h in logging.root.handlers[:]:
            if isinstance(h, logging.StreamHandler) and not isinstance(h, logging.FileHandler):
                logging.root.removeHandler(h)
        # 切换到日志目录作为工作目录
        os.chdir(os.path.dirname(LOG_FILE))

    atexit.register(cleanup)
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    conn = init_db()

    # 回填模式：标记已有文件，不上传
    if args.backfill:
        log.info("=" * 58)
        log.info("  回填模式: 比对 NAS 数据库标记已有文件")
        log.info(f"  目录: {watch_dir}")
        log.info("=" * 58)
        total, matched = backfill_from_nas(watch_dir, conn)
        log.info(f"✅ 回填完成: 检查 {total} 个文件，标记 {matched} 个已有记录")
        return

    # 重传模式：用正确 MIME 类型重新上传
    if args.reupload:
        log.info("=" * 58)
        log.info("  重传模式: 用正确 MIME 类型重新上传 _imported/ 中的文件")
        log.info(f"  目录: {watch_dir}")
        log.info("=" * 58)
        total, uploaded = reupload_from_imported(watch_dir, conn)
        log.info(f"✅ 重传完成: 检查 {total} 个，上传 {uploaded} 个")
        return

    # 清理模式：检测并删除重复记录
    if args.cleanup:
        log.info("=" * 58)
        mode = "预览" if args.dry_run else "执行"
        log.info(f"  清理模式: {mode} NAS 数据库中重复的发票记录")
        log.info("=" * 58)
        groups, deleted = cleanup_nas_duplicates(dry_run=args.dry_run)
        if args.dry_run:
            log.info(f"✅ 预览完成: 发现 {groups} 组重复")
            log.info(f"   使用 --cleanup（不加 --dry-run）执行实际删除")
        else:
            log.info(f"✅ 清理完成: 发现 {groups} 组，删除 {deleted} 条")
        return

    log.info("=" * 58)
    log.info("  ECS 发票自动上传监听")
    log.info(f"  监听: {watch_dir}")
    log.info(f"  上传: {NAS_HOST}")
    log.info(f"  间隔: {args.interval}秒")
    log.info(f"  日志: {LOG_FILE}")
    log.info(f"  停止: kill `cat {PID_FILE}`")
    log.info("  检测范围: 新增文件 + 内容修改")
    log.info("  NAS 系统: 零改动")
    log.info("=" * 58)

    # 首次扫描
    # ======== 启动前健康检查 ========
    startup_ok = _check_nas_connectivity()
    if not startup_ok:
        log.warning("NAS 当前不可达，将进入等待模式")
        _handle_nas_disconnect()
    

    log.info("首次扫描已有文件...")
    files = scan_directory(watch_dir, conn)
    if files:
        log.info(f"发现 {len(files)} 个待处理文件")
        seen_init = set()
        for fpath in files:
            basename = os.path.basename(fpath)
            fsize = os.path.getsize(fpath)
            cycle_key = f"{basename}:{fsize}"
            if cycle_key in seen_init:
                rel = os.path.relpath(fpath, os.path.abspath(watch_dir))
                log.info(f"⏭ 跳过（本周期已处理同名同大小文件）: {rel}")
                fhash = compute_hash(fpath)
                upsert_record(conn, rel, fhash, fsize, os.path.getmtime(fpath))
                continue
            seen_init.add(cycle_key)
            process_file(fpath, conn)
    else:
        log.info("无待处理文件，进入监听循环")

    # 监听循环
    log.info(f"监听中（每 {args.interval} 秒扫描一次）...")
    count = 0
    try:
        while True:
            time.sleep(args.interval)
            
            # ======== v4.8：定时重试 _failed/ 目录 ========
            global _last_failed_retry
            if count - _last_failed_retry >= FAILED_RETRY_INTERVAL // args.interval:
                _last_failed_retry = count
                retry_failed_files(watch_dir, conn)
            
            # ======== v4.8：NAS 连通性检查（指数退避） ========
            if _nas_down_since > 0:
                delay = _get_backoff_delay()
                backoff_elapsed = time.time() - _nas_down_since
                if backoff_elapsed < delay:
                    continue
                alive = _check_nas_alive()
                if not alive:
                    continue
            

            # 重置周期去重集（防止同一个扫描周期内处理同名文件的两份副本）
            # 注意：此去重集生存周期为一个扫描周期，跨周期由 check_nas_duplicate 处理
            seen_in_cycle = set()
            files = scan_directory(watch_dir, conn)
            
            # ======== v4.8：快速路径 — 无文件时心跳检测 NAS ========
            if not files:
                if count % 30 == 0 and _nas_down_since <= 0:
                    _check_nas_alive()
                continue
            

            for fpath in files:
                basename = os.path.basename(fpath)
                fsize = os.path.getsize(fpath)
                cycle_key = f"{basename}:{fsize}"
                if cycle_key in seen_in_cycle:
                    log.info(f"⏭ 跳过（本周期已处理同名同大小文件）: {os.path.relpath(fpath, os.path.abspath(watch_dir))}")
                    # 记录到本地去重库，避免下一周期再扫描
                    rel = os.path.relpath(fpath, os.path.abspath(watch_dir))
                    fhash = compute_hash(fpath)
                    upsert_record(conn, rel, fhash, fsize, os.path.getmtime(fpath))
                    continue
                seen_in_cycle.add(cycle_key)
                try:
                    process_file(fpath, conn)
                except Exception as e:
                    log.error(f"⚠ 处理文件异常: {os.path.relpath(fpath, os.path.abspath(watch_dir))} → {e}")
                    import traceback
                    log.error(traceback.format_exc())
            count += 1
            if count % 120 == 0:  # 约10分钟一次心跳
                elapsed_sec = args.interval * count
                log.info(f"心跳: 持续监听中...（{elapsed_sec}秒）")
    except KeyboardInterrupt:
        log.info("用户手动停止")


def _signal_handler(signum, frame):
    log.info(f"收到信号 {signum}，退出...")
    sys.exit(0)


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)
    main()

