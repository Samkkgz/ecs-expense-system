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
├── nas/                            ← 🟢 NAS Docker 自托管版
│   ├── docker-compose.yml          ← 6 容器编排（db + gateway + auth + rest + storage + ocr）
│   ├── index.html                  ← 前端（连 NAS 本地 http://192.168.3.150:18000）
│   ├── kong.yml                    ← Kong API 网关配置
│   ├── nginx.conf                  ← Nginx 反向代理配置
│   ├── sql/init.sql                ← 数据库完整初始化脚本
│   └── ocr-service/                ← Python OCR 识别服务（替代 Supabase Edge Function）
│       ├── Dockerfile
│       ├── app.py
│       └── requirements.txt
│
├── .gitignore / README.md / VERSIONS.md  ← 项目级文档
├── .agents/                        ← Agent 约定（NAS 部署检查清单等）
├── AGENTS.md                       ← 本文件（Agent 指令）
└── 明天跑这个.txt                   ← 部署步骤备忘录
```

## 开发 & 部署区分

| 场景 | 操作哪个目录 | 部署方式 |
|------|-------------|---------|
| 修改云版前端 | `cloud/index.html` | git push → GitHub Pages 自动部署 |
| 部署 Edge Function | `cloud/supabase/functions/` | `supabase functions deploy` |
| 修改 NAS 版前端 | `nas/index.html` | 复制到 NAS → `docker compose up -d` |
| 修改 NAS 容器配置 | `nas/docker-compose.yml` | 同上 |
| 修改 NAS 版 OCR | `nas/ocr-service/` | 同上 |

## 禁止行为
- 不在 `cloud/` 中存放 NAS 相关代码
- 不在 `nas/` 中存放 Supabase 云服务相关代码
- 修改云版时不影响 NAS 版，反之亦然
- `.env` 文件不提交 git（已由 .gitignore 排除）
