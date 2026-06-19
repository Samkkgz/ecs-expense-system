# ECS-Expanse-System — 开发规范

## 项目结构（两套代码严格分离）

```
ECS-Expanse-System/
│
├── cloud/                          ← 🔵 Supabase 云版
│   ├── index.html                  ← GitHub Pages 入口（连 Supabase Cloud）
│   ├── schema.sql                  ← Supabase 数据库 Schema
│   ├── seed.sql                    ← 种子数据
│   ├── process_expenses.py         ← 报销数据处理脚本
│   └── supabase/functions/
│       └── process-invoice/index.ts ← Edge Function（OCR 识别）
│
├── nas/                            ← 🟢 NAS Docker 自托管版 (v4.5)
│   ├── docker-compose.yml          ← 5 容器编排（db + auth + rest + storage + ocr）
│   ├── index.html                  ← 前端（连 NAS 本地 http://192.168.3.150:18000）
│   ├── nginx.conf                  ← Nginx 反向代理配置
│   ├── kong.yml                    ← Kong API 网关配置
│   ├── sql/init.sql                ← 数据库完整初始化脚本
│   └── ocr-service/                ← Python OCR 识别服务（纯 stdlib，无 pip 依赖）
│       ├── Dockerfile
│       ├── app.py
│       └── requirements.txt
│
├── .github/workflows/
│   └── deploy.yml                  ← push main → 自动部署 cloud/ 到 Pages
├── .gitignore / README.md / VERSIONS.md
├── AGENTS.md
└── 明天跑这个.txt
```

## 开发 & 部署区分

| 场景 | 操作哪个目录 | 部署方式 |
|------|-------------|---------|
| 修改云版前端 | `cloud/index.html` | git push main → GitHub Actions → Pages |
| 部署 Edge Function | `cloud/supabase/functions/` | `cd cloud && supabase functions deploy process-invoice` |
| 修改 NAS 版前端 | `nas/index.html` | 复制 nas/ 到 NAS → `docker compose up -d` |
| 修改 NAS 容器配置 | `nas/docker-compose.yml` | 同上 |
| 修改 NAS 版 OCR | `nas/ocr-service/` | 同上 |

## 注意
- NAS 版当前版本 v4.5（OCR 纯 stdlib，5 容器，named volumes）
- `nas/` 目录代码与 NAS 上 `/volume1/docker/ecs-expense/` 保持一致
- 如修改 `nas/` 代码，需同步复制到 NAS 部署目录
- `.env` 文件不提交 git（已由 .gitignore 排除）
