# ECS 报销管理系统 - 迁移到群晖 NAS

## 架构

```
你的浏览器 → 前端 index.html（可以放 NAS Web Station 或 GitHub Pages）
                   ↓
          192.168.3.150:8000 (Kong API 网关)
              ↙     ↓      ↘
         GoTrue   PostgREST   Storage API
         (认证)    (数据库)    (文件存储)
              ↓     ↓      ↓
               PostgreSQL
```

## 部署步骤

### 第一步：准备配置

1. SSH 进 NAS 或打开 NAS 的 Terminal（控制面板 → 终端机和 SNMP → 启用 SSH）
2. 将本目录复制到 NAS（通过 File Station 或 scp）
3. 编辑 `.env` 文件，修改以下配置：

   ```bash
   # 必须修改：
   POSTGRES_PASSWORD  → 设置一个强密码
   JWT_SECRET         → 设置一长串随机字符
   SMTP_ADMIN_EMAIL   → 你的发件人邮箱
   SMTP_HOST          → SMTP 服务器地址
   SMTP_PORT          → SMTP 端口
   SMTP_USER          → 你的邮箱
   SMTP_PASS          → SMTP 授权码（不是邮箱密码！）
   ```

### 第二步：启动服务

```bash
# 进入目录
cd /path/to/ecs-supabase-nas

# 启动所有服务
docker compose up -d

# 查看启动日志
docker compose logs -f
```

第一次启动大约需要 2-3 分钟。看到类似以下日志表示启动成功：

```
ecs-db       | LOG:  database system is ready to accept connections
ecs-auth     | GoTrue API started on :9999
ecs-rest     | Listening on port 3000
ecs-kong     | kong entered the running phase
```

### 第三步：验证服务

打开浏览器验证以下地址：

| 地址 | 用途 | 预期结果 |
|---|---|---|
| http://192.168.3.150:8000 | Kong API 网关 | 返回 404（正常，因为没有匹配的路由） |
| http://192.168.3.150:8080 | Supabase Studio 管理后台 | 显示登录页面 |
| http://192.168.3.150:8000/rest/v1/ | REST API | 返回 401（正常，需要认证） |

### 第四步：按照 Storage Bucket

```bash
# 进入 PostgreSQL 确认 bucket 已创建
docker exec ecs-db psql -U supabase_admin -d postgres -c "SELECT * FROM storage.buckets;"
```

如果 `invoices` bucket 不存在，手动创建：

```bash
docker exec ecs-db psql -U supabase_admin -d postgres -c "
INSERT INTO storage.buckets (id, name, public) VALUES ('invoices', 'invoices', false)
ON CONFLICT (id) DO NOTHING;"
```

### 第五步：迁移现有数据（从 Supabase Cloud）

> **先不要操作这一步**，先确认新跑的通，再迁移历史数据。

```bash
# 需要先获取 Supabase Cloud 的连接信息
# 在 Supabase Dashboard → Settings → Database → Connection string
# 然后用 pg_dump 导出数据，再导入到 NAS

# 导出（在本地电脑执行）
pg_dump --no-owner --no-acl --data-only \
  "postgresql://postgres:XXX@db.xxxxx.supabase.co:5432/postgres" \
  > /tmp/supabase_dump.sql

# 拷贝到 NAS 后导入（在 NAS 执行）
docker exec -i ecs-db psql -U supabase_admin -d postgres < /tmp/supabase_dump.sql
```

### 第六步：修改前端配置

编辑 `index.html`，修改以下两处：

```diff
- const SUPABASE_URL = 'https://cgeqreslzrdccdisaloe.supabase.co';
+ const SUPABASE_URL = 'http://192.168.3.150:8000';

- const SUPABASE_ANON_KEY = 'sb_publishable_...';
+ const SUPABASE_ANON_KEY = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.ecs-anon-key-2026';
```

以及登录后的跳转地址：

```diff
- return fetch(SUPABASE_URL + '/auth/v1/otp?redirect_to=https://samkkgz.github.io/ecs-expense-system/', {
+ return fetch(SUPABASE_URL + '/auth/v1/otp?redirect_to=http://192.168.3.150:8000/', {
```

### 第七步：访问系统

- 在浏览器打开你的 `index.html`
- 输入邮箱，点击发送登录链接
- 去邮箱点击链接 → 登录成功 → 开始使用

## 如需外网访问

方案一：**群晖自带反代（推荐）**
1. 控制面板 → 登录门户 → 高级 → 反向代理
2. 新建规则：
   - 来源：HTTPS → 你的 DDNS 域名 → 端口 443
   - 目的地：HTTP → localhost:8000
3. 控制面板 → 安全性 → 证书 → 申请 Let's Encrypt 证书
4. 修改前端 `SUPABASE_URL` 为 `https://你的域名`
5. 同时修改 `.env` 中的 `PUBLIC_URL` 和 `SITE_URL` 为 HTTPS 地址

方案二：**Caddy 自动 HTTPS**
在 docker-compose.yml 中添加 Caddy 服务，自动申请和续期 SSL 证书。

## 常用命令

```bash
# 查看所有容器状态
docker compose ps

# 查看日志
docker compose logs -f

# 重启单个服务
docker compose restart auth

# 停止所有服务
docker compose down

# 更新镜像后重新创建容器
docker compose pull
docker compose up -d
```
