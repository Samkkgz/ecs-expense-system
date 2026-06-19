# ECS Expense System - Version History

## v3.4 (2026-06-14) - 当前版本 ✅
**改动**：修复 GoTrue 迁移 `role "postgres" does not exist`

### 修复
- init.sql 新增 `CREATE ROLE IF NOT EXISTS postgres`（GoTrue 迁移 `20240612...enable_rls_update_grants.up.sql` 需要 `postgres` 角色，但 supabase/postgres 镜像用 `supabase_admin`）
- 目录升至 pgdata4（确保全新初始化）

### 架构
- 6 容器：db / gateway(nginx) / auth(gotrue) / rest(postgrest) / storage / ocr
- 密码登录（无邮件依赖）
- bind mount（非 Docker volumes）
- 无 depends_on（restart: always 处理启动顺序）

---

## v3.3 - bind mount + ALTER ROLE
- 用 bind mount 替代 Docker named volumes
- 用 ALTER ROLE 强制设置所有角色密码

## v3.2 - supabase_admin + 完整 init.sql
- 从 nas-deploy 重建，硬编码密码
- 修复 signUp 回退逻辑和 profile 自动创建

## v3.1 - 部署包初版（已废弃）
- init.sql 缺失 auth schema，GoTrue 迁移失败

## v3 - NAS Supabase 自托管（早期）
- 6 容器能跑但 magic link 邮件失败

## v2 - Docker 单容器
- 单容器 Flask 方案

## v1 - Supabase Cloud
- supabase.com 云服务
