# ECS 报销管理系统

基于 **GitHub + Supabase** 的团队报销管理解决方案。自动识别发票、生成月度/季度/年度报表。

## 技术栈

- **前端**: GitHub Pages (纯 HTML + Supabase JS SDK + Chart.js)
- **后端**: Supabase (PostgreSQL + Storage + Auth + Edge Functions)
- **OCR识别**: 浏览器端 Tesseract.js（延迟加载，不阻塞页面）

## 系统架构

```
用户上传PDF发票 → Supabase Storage
       ↓
浏览器端 OCR 识别（点击 🔄 按钮触发）
       ↓
自动提取发票号码、金额、商家等信息 → 存入 PostgreSQL
       ↓
Dashboard 展示月度/季度/年度报表
```

## 功能特点

### ✅ 已完成
- 📧 邮箱登录（Magic Link）
- 📤 PDF发票上传（拖拽或点击）
- 🖼️ 浏览器端 OCR 识别（支持 CID 编码的 PDF）
- 🔄 OCR 结果自动提取（发票号码、日期、商家、金额）
- ✏️ 编辑发票信息
- ✅ 审核通过/驳回
- 📊 月度/季度/年度统计报表
- 📈 费用趋势图表
- 🏷️ 自动归类（餐饮、交通、住宿等）

### 🚧 待完善
- Supabase Edge Function Webhook 自动识别
- 导出 CSV/Excel 报表
- 多用户权限管理

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

## 使用说明

### 上传发票
1. 打开 https://samkkgz.github.io/ecs-expense-system/
2. 输入邮箱 → 发送登录链接 → 查收邮件点链接登录
3. 点左边 **上传发票** → 拖拽或选择 PDF 文件
4. 选择归属月份和（可选）费用类目 → 上传

### OCR 识别
1. 上传后在 **发票管理** 页面找到记录
2. 点 **🔄** 按钮 → 自动下载PDF → OCR识别
3. 自动提取：发票号码、日期、商家名称、金额
4. 自动保存到数据库，弹出编辑窗口核对
5. 确认无误点 **通过** → 数据进入报表统计

### 查看报表
- **仪表盘**: 当月/当季/全年费用总览
- **统计报表**: 月度/季度/年度详细报表
- 支持图表展示费用趋势和类目分布

## 本地开发

### 修改前端
编辑 `index.html`，提交后 GitHub Pages 自动更新。

### 重新部署 Edge Function
```bash
supabase functions deploy process-invoice --no-verify-jwt
```

### 配置 Webhook（可选）
Supabase Dashboard → Database → Webhooks → 创建新 hook：
- Name: `ocr-on-insert`
- Table: `invoices`
- Events: `Insert`
- Type: `Supabase Edge Function`
- Function: `process-invoice`

## 项目结构

```
ecs-expense-system/
├── index.html                   # 前端主页面（全部功能）
├── schema.sql                   # 数据库 Schema
├── seed.sql                     # 种子数据
├── supabase/
│   └── functions/
│       └── process-invoice/
│           └── index.ts         # Edge Function
└── README.md
```
