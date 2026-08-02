# ECS-Expanse-System — 开发规范

> ⚠️ 任务启动：请使用 `[DEV]` 前缀 + 版本标识，如 `[DEV] ECS 报销系统：修复 NAS 版 OCR`


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

## 版本号管理
- 项目版本号统一在 VERSIONS.md 中维护，入口文件（cloud/index.html、nas/index.html）头部标注当前版本号
- 遵循语义化版本规范（major.minor.patch）：
  - 产品功能变更 → 递增次版本号（minor）
  - Bug 修复/小优化 → 递增补丁版本号（patch）
  - 重大架构变更 → 递增主版本号（major）
- 每次发布前必须递增版本号，确保所有发布可追溯

## 修改前备份（强制执行）
- **任何代码修改前，必须先做完整备份**：git commit 提交当前版本 + NAS 全量备份（scripts/nas-backup.sh）
- 备份完成后标注当前版本号（Git commit hash 或版本标签），后续修改方可进行
- 涉及 NAS 部署的修改，需额外确认 NAS 上运行版本已通过 Git commit 记录

## 业务规则（已上线，禁止臆断）

- **公司归属变更**：超级管理员可在管理员面板修改用户所属公司；变更后，新上传/新申请发票归新公司，已完成审批或已申请审批的发票保持归原公司
- **自动上传归属**：从本机自动上传的发票默认归属 sam.lu@ecsomni.com（超级管理员）
- **审批中心筛选**：管理员/超级管理员可查看自己和下属的发票，支持按用户筛选；公司/用户/状态筛选变更后自动刷新
- **发票自动上传稳定性**：`_failed/` 目录每 30 分钟自动重试，NAS 不可达时指数退避；上传进程由 `ecs-upload.sh` 管理，异常退出需告警检查

## 注意
- NAS 版当前版本 v4.5（OCR 纯 stdlib，5 容器，named volumes）
- `nas/` 目录代码与 NAS 上 `/volume1/docker/ecs-expense/` 保持一致
- 如修改 `nas/` 代码，需同步复制到 NAS 部署目录
- `.env` 文件不提交 git（已由 .gitignore 排除）
