# ECS 报销管理系统 - Docker 自托管版

将 ECS 报销管理系统部署到 NAS 或任何 Docker 环境，无需依赖 Supabase。

## 快速部署

### 1. 准备工作
在 NAS 的 Container Manager 中：
- 创建项目文件夹（或在当前目录操作）
- 确保 8888 端口未被占用（可在 docker-compose.yml 中修改）

### 2. 启动服务
```bash
# 进入项目目录
cd /volume1/docker/ecs-expense

# 启动（后台运行）
docker-compose up -d
```

### 3. 访问系统
浏览器打开 `http://NAS_IP:8888`

### 4. 登录
- 默认管理员: `admin@ecsomni.com`
- 默认密码: `admin123`

## 配置

编辑 `config.env` 文件（可选）：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| SECRET_KEY | 会话加密密钥 | ecs-expense-secret-key-change-me |
| ADMIN_EMAIL | 管理员邮箱 | admin@ecsomni.com |
| ADMIN_PASSWORD | 管理员密码 | admin123 |
| BAIDU_API_KEY | 百度OCR API Key | (留空则无法OCR) |
| BAIDU_SECRET_KEY | 百度OCR Secret Key | (留空则无法OCR) |

## 数据存储
所有数据保存在 `./data/` 目录：
- `database.db` - SQLite 数据库（用户、发票、类别）
- `invoices/` - 上传的发票文件（按年/月组织）
- `backups/` - 自动备份

## 功能
- ✅ 用户注册/登录（邮箱+密码）
- ✅ 发票上传（拖拽/点击，支持 PDF/图片）
- ✅ 百度 OCR 自动识别
- ✅ 发票管理（编辑/审核/删除）
- ✅ 多用户隔离（成员只看自己，管理员看全部）
- ✅ 统计报表（月度/季度/年度）
- ✅ Excel 导出（含明细+类目汇总）
- ✅ 管理员面板（用户管理/角色设置/删除用户/重置密码）
- ✅ 费用类目管理
- ✅ 自动地点识别（非广州=出差）
