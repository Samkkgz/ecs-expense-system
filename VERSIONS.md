# ECS Expense System - Version History

## v4.7 (2026-07-29) - 当前版本 ✅
**改动**：添加财务类目功能，支持类目映射、筛选与汇总

### 关键变更
- schema/seed：`expense_categories` 新增 `financial_category` 列，含 mapping 种子数据
- 类目管理：显示/编辑/新增「财务类目」字段，可选：办公费、差旅费、招待费、福利费、通讯费
- 统计报表：新增「财务类目」筛选器，报表内显示财务类目汇总表
- 导出报表：Excel 含财务类目列 + 财务类目汇总 sheet
- 迁移脚本：`cloud/schema-financial-category.sql` 用于 Supabase 存量数据库迁移

---

## v4.6 (2026-07-29)
**改动**：修复 storage_path 无效值的 400 错误，增加前置校验

### 关键变更
- `loadPreview()` & `ocrInvoice()` in nas/index.html：加 `storage_path` 非空/长度校验，预览失败友好提示
- `editInvoice()` & `ocrInvoice()` in cloud/index.html：加 `hasFile` 条件判断，空路径时显示"暂无文件"而非发送 400 请求
- 统一前端文件预览/OCR/删除/导出等操作对 `storage_path` 的防御性校验

---

## v4.5 (2026-06-14)
**改动**：OCR 纯 stdlib（无 pip 依赖）+ 健康检查 + 错误传播

### 架构
- 5 容器：db / auth(gotrue) / rest(postgrest) / storage / ocr
- 密码登录（无邮件依赖）
- 使用 Docker named volumes（`ecs_pgdata_v17`）
- 无 nginx 网关（架构简化）

### 关键变更
- OCR 服务改用纯 Python stdlib，无需 pip install
- 健康检查增强：pg_isready + schema 确认双重检查
- 错误传播机制改进

---

## v3.4 — GoTrue 迁移修复
- init.sql 新增 `CREATE ROLE IF NOT EXISTS postgres`
- 修复 GoTrue 迁移 `role "postgres" does not exist`
- 6 容器：含 nginx 网关

## v3.3 — bind mount + ALTER ROLE
- 用 bind mount 替代 Docker named volumes
- 用 ALTER ROLE 强制设置所有角色密码

## v3.2 — supabase_admin + 完整 init.sql
- 从 nas-deploy 重建，硬编码密码

## v3.1 — 部署包初版（已废弃）
- init.sql 缺失 auth schema，GoTrue 迁移失败

## v3 — NAS Supabase 自托管（早期）
- 6 容器能跑但 magic link 邮件失败

## v2 — Docker 单容器
- 单容器 Flask 方案

## v1 — Supabase Cloud
- supabase.com 云服务

# v4.8 (2026-07-30) - 当前版本 ✅
**改动**：修复自动上传进程崩溃后不自启问题，增强系统稳定性机制

### 关键变更
- 自动上传守护进程崩溃后不自启 → plist 设置 KeepAlive=true，进程崩溃后自动重启
- 上传失败文件永不重试 → 新增 _failed/ 目录定期重试机制（每30分钟扫描一次）
- NAS 断连时无限空转浪费资源 → 新增连通性检查 + 指数退避等待（30s→600s）
- 无信号处理导致 PID 文件残留 → 注册 SIGTERM/SIGINT 信号处理器
- 前置启动检查确保已知状态 → 启动前检查 NAS 连通性，不可达时进入等待模式

### 相关文件
- `nas/scripts/auto_upload_invoices.py` — 主脚本增强
- `nas/scripts/com.ecs.auto-upload.plist` — plist 配置
- `nas/scripts/control.sh` — 控制脚本

---

