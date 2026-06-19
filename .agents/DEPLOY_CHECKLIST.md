# NAS 部署检查清单（每次交付前逐项核查）

## 0. 版本号约定
- 每次修改 compose/init.sql 必须更新版本号（v3.4→v3.5→...）
- 版本号写在 compose 第一行注释、init.sql 第一行注释、.env 注释
- 与版本相关的卷/目录名必须唯一（ecs_pgdata_v5 ≠ ecs_pgdata_v4）

## 1. Docker 卷陷阱（v3.5 更新）
- [ ] ❌ 不用 bind mount 做 PostgreSQL 数据目录！Synology BTRFS/ACL 阻止容器写入
- [ ] ✅ 用 Docker 命名卷：`ecs_pgdata_v5:/var/lib/postgresql/data`
- [ ] ✅ 每次部署用新卷名（`ecs_pgdata_v5`→`ecs_pgdata_v6`）
- [ ] ✅ Storage 文件也用命名卷：`ecs_storage_v5:/var/lib/storage`
- [ ] ⚠️  命名卷不会被 DSM 的"清除"按钮删除，需在 Container Manager → 卷 手动清理旧卷

## 2. 目录预创建（v3.5：仅配置文件需要 bind mount）
- [ ] ✅ 配置文件的 bind mount 目录需要预创建并 chmod（nginx.conf, init.sql, index.html, app.py）
- [ ] ❌ 不再需要 pgdata 和 storage-data 目录

## 3. 数据库角色（v3.5 更新）
- [ ] ✅ `ALTER ROLE xxx WITH LOGIN PASSWORD` 直接重置密码（supabase/postgres 镜像设了随机密码）
- [ ] ✅ 必须重置三个角色：`supabase_auth_admin`、`supabase_storage_admin`、`authenticator`
- [ ] ✅ 创建 `postgres` 角色（GoTrue v2 迁移需要用它做 RLS grant）
- [ ] ✅ `GRANT ALL ON SCHEMA auth TO supabase_admin`（确保 auth 能迁移）

## 4. auth schema
- [ ] ✅ supabase/postgres 镜像已创建 auth schema，init.sql 不需要 CREATE SCHEMA
- [ ] ✅ `CREATE OR REPLACE FUNCTION auth.uid()` 和 `auth.role()` 确保存在
- [ ] ✅ `GRANT EXECUTE ON FUNCTION auth.uid(), auth.role() TO anon, authenticated`

## 5. compose 兼容性
- [ ] ❌ 不用 `depends_on`（DSM 可能不支持）
- [ ] ❌ 不用 `healthcheck`（DSM 某些版本不支持）
- [ ] ✅ 用 `restart: always` 处理启动顺序
- [ ] ✅ 所有 compose 中的 DB URL 密码一致

## 6. nginx
- [ ] ✅ `resolver 127.0.0.11 valid=30s;` 推迟 DNS 解析
- [ ] ✅ `set $upstream_xxx xxx:port;` + `proxy_pass http://$upstream_xxx/;`

## 7. 密码一致性
- [ ] ✅ compose 所有 DB URL 密码一致（ecs_supabase_2026）
- [ ] ✅ init.sql ALTER ROLE 密码与 compose 一致
- [ ] ✅ JWT_SECRET 在 auth/rest/storage 三处一致

## 8. 登录
- [ ] ✅ GoTrue v2 用密码登录（`GOTRUE_EXTERNAL_PASSWORD_ENABLED: "true"`）
- [ ] ✅ `GOTRUE_MAILER_AUTOCONFIRM: "true"` 跳过邮箱验证
- [ ] ✅ `GOTRUE_DISABLE_SIGNUP: "false"` 允许首次注册
- [ ] ✅ 首次登录自动创建 profile

## 9. v3.5 核心修复
- [ ] ✅ pgdata 从 bind mount 改为命名卷（解决 Synology 权限问题）
- [ ] ✅ 用 ALTER ROLE 替代 DO $$ CREATE ROLE（镜像已有角色，只需重置密码）
- [ ] ✅ 创建 postgres 角色供 GoTrue 迁移使用
- [ ] ✅ 移除了 healthcheck（DSM 兼容性）

---

## 10. 交付前强制审计流程（v3.5.2 新增，防漏）

每次修改 init.sql 或 compose 后，**必须**运行以下审计再交付：

### 角色审计
- [ ] 列出每个容器需要的数据库角色
- [ ] auth(GoTrue): supabase_auth_admin, postgres
- [ ] rest(PostgREST): authenticator(LOGIN), anon, authenticated, service_role
- [ ] storage: supabase_storage_admin, service_role
- [ ] 用自动化脚本验证 init.sql 覆盖所有角色

### Schema 审计
- [ ] auth schema: GoTrue 迁移用
- [ ] storage schema: storage-api 迁移用
- [ ] extensions schema: PostgREST search_path 用

### 权限审计
- [ ] GRANT anon/authenticated/service_role TO authenticator
- [ ] GRANT USAGE ON SCHEMA auth/storage/extensions TO 所有角色
- [ ] GRANT ALL ON SCHEMA auth TO supabase_admin
- [ ] GRANT ALL ON SCHEMA storage TO supabase_admin, supabase_storage_admin

### 交付前命令
```bash
python3 << 'PYEOF'
# 自动验证 init.sql 完整性
import re
with open("init.sql") as f:
    sql = f.read()
required = [
    "anon", "authenticated", "service_role", "authenticator",
    "supabase_auth_admin", "supabase_storage_admin", "postgres",
    "CREATE SCHEMA IF NOT EXISTS auth",
    "CREATE SCHEMA IF NOT EXISTS storage",
    "CREATE SCHEMA IF NOT EXISTS extensions",
    "GRANT anon TO authenticator",
    "GRANT authenticated TO authenticator",
    "GRANT service_role TO authenticator",
]
for item in required:
    assert item in sql, f"MISSING: {item}"
print("ALL OK")
PYEOF
```
