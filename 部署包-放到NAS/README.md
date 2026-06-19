# ECS 报销管理系统 - NAS 部署包

## 版本历史

| 版本 | 日期 | 关键变更 |
|------|------|---------|
| v4.4 | 2026-06-14 | ✅ GoTrue auto-migrate 启用（修复登录注册）；nginx 自动映射 apikey→Bearer（修复storage认证）；OCR 重试机制 |
| v4.3 | 2026-06-14 | JWT 密钥统一为 `ecs-jwt-secret-2026-v3` |
| v4.2 | 2026-06-14 | 修复密码认证 |
| v4.1 | 2026-06-13 | 完整表初始化 |
| v4.0 | 2026-06-13 | 初始 NAS 自托管版 |

## 文件说明

```
部署包-放到NAS/
├── docker-compose.yml    # 主配置（v4.4）
├── index.html             # 前端页面（v4.3）
├── nginx.conf             # 网关路由（v4.4 - 支持 apikey→Bearer 映射）
├── sql/
│   └── init.sql           # 数据库初始化（v4.4 - 不再手动创建 auth 表）
├── ocr-service/
│   └── app.py             # OCR 识别服务
├── setup-admin.sh         # 管理员账户设置脚本
└── README.md              # 本文件
```

## 部署步骤

### 1. 上传文件到 NAS
```bash
# 在 Mac 上执行
cat 部署包-放到NAS/docker-compose.yml | ssh sam.lu@192.168.3.150 "cat > /volume1/docker/ecs-expense/docker-compose.yml"
cat 部署包-放到NAS/nginx.conf | ssh sam.lu@192.168.3.150 "cat > /volume1/docker/ecs-expense/nginx.conf"
cat 部署包-放到NAS/index.html | ssh sam.lu@192.168.3.150 "cat > /volume1/docker/ecs-expense/index.html"
cat 部署包-放到NAS/sql/init.sql | ssh sam.lu@192.168.3.150 "cat > /volume1/docker/ecs-expense/sql/init.sql"
```

### 2. 在 DSM Container Manager 中
- 项目 → 操作 → 清除（如有旧项目）
- 项目 → 新增 → 从 docker-compose.yml 创建
- 路径：`/volume1/docker/ecs-expense`
- 项目名称：`ecs-expense-v4`

### 3. 运行验收测试
```bash
bash ecs-expense-system/test-deploy.sh
```

### 4. 登录
- 地址：http://192.168.3.150:18000
- 首次登录自动注册管理员
- 邮箱：sam.lu@ecsomni.com
- 密码：ecs2026

## 服务端口

| 服务 | 内部端口 | 外部端口 | 说明 |
|------|---------|---------|------|
| gateway (nginx) | 8000 | 18000 | 统一入口 |
| db (PostgreSQL) | 5432 | 15432 | 数据库 |
| auth (GoTrue) | 9999 | - | 身份认证 |
| rest (PostgREST) | 3000 | - | REST API |
| storage | 5000 | - | 文件存储 |
| ocr | 9000 | - | 发票识别 |

## 密码

| 用途 | 用户名 | 密码 |
|------|--------|------|
| 数据库 | supabase_admin | ecs_supabase_2026 |
| 数据库 | authenticator | ecs_supabase_2026 |
| 数据库 | postgres | ecs_supabase_2026 |
| JWT 密钥 | - | ecs-jwt-secret-2026-v3 |
