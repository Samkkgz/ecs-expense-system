# ECS 报销管理系统

基于 **GitHub + Supabase** 的团队报销管理解决方案。自动识别发票、生成月度/季度/年度报表。

## 技术栈

- **前端**: GitHub Pages (纯 HTML + Supabase JS SDK + Chart.js)
- **后端**: Supabase (PostgreSQL + Edge Functions + Storage + Auth)
- **OCR识别**: Supabase Edge Function (Tesseract.js)

## 系统架构

```
用户上传PDF发票 → Supabase Storage
       ↓
Supabase Edge Function (OCR识别)
       ↓
PostgreSQL 存储结构化数据
       ↓
前端 Dashboard 展示报表
```

## 部署步骤

### 1. 创建 Supabase 项目

1. 访问 [supabase.com](https://supabase.com) 并创建新项目
2. 记下 Project URL 和 anon key

### 2. 配置数据库

在 Supabase SQL Editor 中依次运行：

1. `schema.sql` - 创建所有数据表、索引、RLS策略
2. `seed.sql` - 导入费用类目种子数据

### 3. 配置 Storage

在 Supabase Dashboard 中：

1. 进入 **Storage** → 创建新 bucket `invoices`
2. 设置公共访问策略（或配置 RLS）

### 4. 部署 Edge Function

```bash
# 安装 Supabase CLI
npm install -g supabase

# 登录
supabase login

# 链接项目
supabase link --project-ref YOUR_PROJECT_REF

# 部署函数
supabase functions deploy process-invoice
```

然后在 Supabase Dashboard 中为 `process-invoice` 函数设置：

- **Database Webhook**: 当 `invoices` 表 INSERT 时触发
- 或者使用 **Storage Webhook**: 当文件上传到 `invoices` bucket 时触发

### 5. 配置 Auth

1. 进入 **Authentication** → **Settings**
2. 启用 **Email** 登录方式
3. （可选）配置自定义 SMTP 以自定义发件人

### 6. 部署前端

#### 方式一：GitHub Pages（推荐）

1. 在 GitHub 创建仓库 `ecs-expense-system`
2. 修改 `index.html` 中的 Supabase 配置：
   ```javascript
   const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
   const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY';
   ```
3. 推送代码后，在仓库 Settings → Pages 中启用
4. 选择 `main` 分支，`/ (root)` 目录

#### 方式二：本地运行

```bash
python3 -m http.server 8000
# 访问 http://localhost:8000
```

### 7. 初始化数据

1. 访问部署好的前端页面
2. 使用邮箱登录
3. 在"上传发票"页面拖拽 PDF 文件上传
4. Edge Function 会自动 OCR 识别并归类

## 使用说明

### 上传发票
- 支持 PDF 格式电子发票
- 上传时选择归属月份和（可选）费用类目
- 支持批量上传多个文件

### 发票管理
- 查看所有发票，支持搜索/过滤
- 点击编辑按钮修改 OCR 识别结果
- 审核通过/驳回发票
- 导出为 CSV/Excel 格式

### 统计报表
- **月度报表**: 当月费用总额、类目分布
- **季度报表**: 按季度汇总
- **年度报表**: 全年费用分析和趋势图

### 费用类目管理
- 预置 8 个常用类目
- 可自定义添加/编辑类目

## 费用类目

| 类目 | 说明 |
|------|------|
| 办公用品 | 办公用品采购 |
| 出差餐饮费 | 出差期间的餐饮支出 |
| 出差交通费 | 机票、高铁、打车等 |
| 出差住房费 | 出差住宿支出 |
| 客情餐饮费 | 客户关系维护餐饮 |
| 日常餐饮费 | 日常团队餐饮 |
| 通讯费 | 手机话费等 |
| 外出交通费 | 本地打车地铁等 |

## OCR 自动识别规则

系统会根据 OCR 提取的商家名称和项目描述自动归类：

- **商家含"餐饮""餐厅"** → 出差餐饮费（如含客情关键词则为客情餐饮费）
- **商家含"酒店""宾馆"** → 出差住房费
- **商家含"石油""石化""加油站"** → 出差交通费（油费）
- **项目含"铁路""高铁""机票"** → 出差交通费
- **商家含"移动""电信""联通"** → 通讯费

## 项目结构

```
ecs-expense-system/
├── index.html                           # 前端主页面
├── schema.sql                           # 数据库 Schema
├── seed.sql                             # 种子数据
├── supabase/
│   └── functions/
│       └── process-invoice/
│           └── index.ts                 # OCR Edge Function
└── README.md
```

## 本地开发

无需本地搭建。所有修改只需编辑 `index.html`，提交后 GitHub Pages 自动更新。

如需测试 OCR，可在本地 Supabase 或使用 Tesseract.js 测试。

## 许可

内部使用
