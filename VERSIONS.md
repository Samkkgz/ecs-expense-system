# ECS Expense System - Version History

## v4.5 (2026-06-14) - 当前版本 ✅
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
