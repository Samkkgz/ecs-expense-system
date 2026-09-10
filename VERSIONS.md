# ECS Expense System - Version History

## v4.20.0 (2026-09-10)
**改动**：用户管理新增超级管理员修改用户登录密码功能

### 关键变更
- 用户管理表格对 `super_admin` 显示“🔑 修改密码”按钮，管理员和其他角色不可见
- 新增数据库 RPC `admin_reset_user_password`：仅允许超级管理员调用，密码长度 6 位至 72 字节，使用 bcrypt 哈希后写入 `auth.users`
- 新增存量数据库迁移 `nas/sql/migration-v4.20.0-admin-reset-user-password.sql`，并同步更新 `nas/sql/init.sql`
- 前端不记录明文密码；修改后既有登录会话保持至 JWT 过期，下次登录使用新密码

### 生产部署与验证 (2026-09-11)
- NAS 已部署 `v4.20.0`：执行 `migration-v4.20.0-admin-reset-user-password.sql`、替换 `index.html`、刷新 PostgREST schema 缓存并重启 `ecs-gateway`
- 生产接口实测：超级管理员调用 RPC 返回 `204`，测试账号使用新密码登录返回 `200`；普通成员调用被拒绝，原密码哈希测试后已恢复且测试密码失效
- Chrome 生产实测：页面版本 `v4.20.0`，超级管理员可进入用户管理，显示 2 个“🔑 修改密码”按钮，密码弹窗正常打开和关闭
- CI：GitHub Actions `NAS regression tests` 通过

### 生产数据变更登记
- 数据来源：本次功能验收，无业务导入数据
- 影响范围：`auth.users` 中测试账号 `sam.lu@bsctradingltd.top` 的 `encrypted_password` / `updated_at` 临时变更 1 次，测试后已恢复至原值
- 备份路径：`/volume1/CodexBackup/ecs-expense/pre-v4.20.0-20260911-001551/postgres-20260911-001551.dump`
- 验证状态：恢复后哈希比对 `true`，测试密码登录失败，无残留数据变更

### 相关文件
- `nas/index.html`
- `nas/sql/init.sql`
- `nas/sql/migration-v4.20.0-admin-reset-user-password.sql`
- `nas/tests/admin-reset-password.test.js`
- `.github/workflows/nas-tests.yml`

---

## v4.19.5 (2026-08-16)
**改动**：自动上传 NAS 地址多链路容灾（局域网直连 + Tailscale 自动切换）+ 长时间断连本地通知

### 背景与根因
- 2026-08-16 10:28 下载的 3 张发票未自动上传：10:27 起脚本固定使用的 Tailscale 地址 100.105.75.56 因本机 VPN 路由冲突不可达（局域网 192.168.3.150 全程正常），脚本判定 NAS 离线后进入退避等待并跳过扫描，3 张发票滞留监听目录 17 分钟
- 同类故障前科：v4.19.2（进程假死不扫描）。本次为「进程存活但 NAS 地址单点依赖」导致的不扫描，属于第二类静默堆积，需机制化防复发

### 关键变更
- 多地址自动容灾：默认按 局域网(192.168.3.150) → Tailscale(100.105.75.56) 顺序探测，当前地址不可达自动切换，恢复后优先回切局域网；显式设置 `ECS_NAS_HOST` 时仍只走指定地址（兼容旧行为）
- 健康检查改用 PostgREST 根路径 `/rest/v1/`，避免把局域网内其他设备的 Web 服务误判为 ECS 网关
- 修复指数退避实现缺陷：原逻辑退避到期后每个扫描周期重复探测并刷日志，现仅在退避时间到期时实际探测一次
- 全部地址不可达持续 10 分钟后发送 macOS 本地通知（断连期间文件不丢失，恢复后自动补传），恢复连接时通知
- 已补传 2026-08-16 下载的 3 张发票（ID 233-235，状态 draft）

### 相关文件
- `nas/scripts/auto_upload_invoices.py`
- `VERSIONS.md`、`AGENTS.md`

---

## v4.19.4 (2026-08-11)
**改动**：修复报表缓存刷新函数 `refresh_expense_report` SQL 错误

### 背景与根因
- 函数三处（月/季/年）写 `JSONB_OBJECT_AGG(c.name, sub.amt)`，引用子查询外部不存在的表别名 `c`（正确应为 `sub`），一调用即报 `missing FROM-clause entry for table c`
- 影响：NAS 无调用方、缓存表空 → 无用户可见影响；云版 Edge Function 调用但吞错 → 缓存永不刷新。属于埋雷问题

### 关键变更
- 修复为 `JSONB_OBJECT_AGG(sub.name, sub.amt)`（NAS `init.sql` + 云版 `schema.sql` 同步）
- NAS 生产库已应用并实测：月/季/年报表缓存正常生成，数值与前端实时统计一致（2026 年度 ¥27,839.02/96 张、2026-08 ¥7,811.85/31 张）

### 相关文件
- `nas/sql/migration-v4.19.4-refresh-expense-report-fix.sql`（新增）
- `nas/sql/init.sql`、`cloud/schema.sql`

---

## v4.19.3 (2026-08-11)
**改动**：修复重复发票清理不掉 + 上传时按发票号过滤重复（照片/PDF 双通道重复）

### 背景与根因
- 生产库出现 3 组同发票号重复（如 `26117000001150356644` 有 2 条：照片 `IMG_9182.JPG` 与自动下载的 PDF `:26117000001150356644_小米官方旗舰店.pdf`），另一组各有 3 条
- 所有查重逻辑（前端上传、自动上传脚本、insert_invoice RPC、清理按钮、数据库唯一索引）都只按 `original_filename + file_size (+ company)` 判重
- 同一张发票的照片和 PDF 文件名不同、大小不同 → 全部查重路径失效；"清理重复"按钮按同样键值分组，自然清不掉
- NAS OCR 服务此前完全没有发票号级去重；云版 Edge Function 只有百度 OCR 路径有（PDF 文字提取路径缺失），且依赖手动触发

### 关键变更
- **上传时过滤**：前端（NAS+云版）与自动上传脚本在文件名含 20 位发票号码时，先查同号记录，已存在则跳过；OCR 识别后同号也合并
- **OCR 去重**：NAS OCR 服务新增发票号级去重，识别出同号已存在时，合并 OCR 数据到旧记录并删除当前记录；云版 Edge Function 文字提取路径补齐同样逻辑
- **清理按钮修复**：清理重复按钮/脚本优先按发票号分组（无号码时退回文件名+大小），照片+PDF 组合现在能被正确识别清理
- **数据库兜底**：新增 `uq_invoices_invoice_number` 部分唯一索引（发票号非空即全局唯一），任何路径都无法再插入同号发票
- **数据清理**：备份后清理 NAS 生产库 3 组重复，每组保留最新一条（存储文件保留）

### 相关文件
- `nas/index.html`、`cloud/index.html`
- `nas/ocr-service/app.py`
- `nas/scripts/auto_upload_invoices.py`
- `nas/sql/migration-v4.19.3-unique-invoice-number.sql`（新增）
- `cloud/schema.sql`、`cloud/supabase/functions/process-invoice/index.ts`

---

## v4.19.2 (2026-08-03) - 当前版本 ✅
**改动**：修复自动上传监听进程「假死」导致新下载发票不自动上传，新增心跳看门狗防复发

### 背景与根因
- 2026-08-03 复发：15:43 上传完上一批发票后，监听进程在 `time.sleep` 中不再唤醒，进程存活、CPU 零增长、无任何日志/网络活动，18:41 新下载的 2 张发票未被扫描上传
- KeepAlive 只能检测「进程崩溃退出」，无法检测「进程存活但不工作」的假死
- 主循环 `count` 只在有文件待处理时才递增，空闲时心跳日志和 `_failed/` 30 分钟重试永不触发，故障时完全无观测信号

### 关键变更
- 监听进程新增心跳：每个扫描周期写入 `/tmp/auto_upload_invoices.heartbeat`，每 5 分钟输出一条心跳日志（修复 count 计数 bug，空闲期也递增）
- 新增 `nas/scripts/watchdog.py` 看门狗：检测进程未运行或心跳超 300 秒（假死）时，`launchctl kickstart -k` 自动重启监听
- 新增 launchd 定时任务 `com.ecs.auto-upload-watchdog`（每 5 分钟运行一次），`enable-auto` / `disable-auto` 同步管理
- 扫描循环增加兜底异常捕获，单次扫描异常只记录日志，不再让整个进程静默退出
- 已补传 2026-08-03 下载的 2 张发票（`26447000001524264216.pdf`、`26447000001520628669.pdf`）

### 相关文件
- `nas/scripts/auto_upload_invoices.py`
- `nas/scripts/watchdog.py`（新增）
- `nas/scripts/com.ecs.auto-upload-watchdog.plist`（新增）
- `nas/scripts/control.sh`
- `VERSIONS.md`

---

## v4.19.1 (2026-08-01) - 当前版本 ✅
**改动**：修复自动上传守护进程死后不自启 + 日志重复 + 双实例问题

### 关键变更
- launchd 改为前台直接管理（去掉 `--daemon`），KeepAlive=true 真正生效，进程退出/崩溃 30 秒内自动重启
- 新增单实例互斥：PID 文件对应进程仍存活时，新实例直接退出，杜绝双进程同时写日志/抢上传
- 日志去重：logging 只保留 FileHandler，不再与 stdout 重定向双写
- 自动上传发票归属到 sam.lu@ecsomni.com 超级管理员名下
- 管理员（super_admin）可在编辑弹窗提交草稿发票审批（draft/rejected → pending），触发器 `prevent_member_status_change` 同步更新
- 上传 `Aug 2026/` 目录 2 张新发票（26442000008836984291、发票金额58元）

### 相关文件
- `nas/scripts/auto_upload_invoices.py`
- `nas/scripts/com.ecs.auto-upload.plist`
- `nas/scripts/control.sh`

---

## v4.19.0 (2026-08-01)
**改动**：审批中心增加用户筛选

### 关键变更
- 审批中心筛选栏新增「全部用户」下拉，可按上传人筛选发票
- 公司、用户、状态筛选选择后自动刷新审批列表，不再需要手动点击刷新

---

## v4.18.1 (2026-08-01) - 当前版本 ✅
**改动**：修复管理员费用统计口径与统计报表用户筛选

### 关键变更
- 管理员面板费用统计不再按当前选中公司过滤，统计名下全部公司的团队费用（含自己）
- 统计报表的「全部用户」筛选现在会真正参与统计与导出，切换用户后报表数据同步变化
- 数据修正：历史无上传人的逸创网络已通过发票（46 张）归属到 `sam.lu@ecsomni.com`，并将其显示名称设置为 `Sam.Lu`

---

## v4.18.0 (2026-08-01) - 当前版本 ✅
**改动**：发票管理增加用户列与用户筛选，方便管理员区分自己和下属的发票

### 关键变更
- 管理员/超级管理员发票列表新增「用户」列，展示发票上传人姓名或邮箱
- 筛选栏新增「全部用户」下拉，可按上传人过滤发票；普通用户不显示该筛选项
- 导出当前筛选结果时同样应用用户筛选

---

## v4.17.0 (2026-07-31) - 当前版本 ✅
**改动**：超级管理员可修改用户所属公司；一次性迁移 `sam.lu@bsctradingltd.top` 及其名下发票到逸创网络

### 关键变更
- 管理员面板新增「修改所属公司」按钮（仅超级管理员可见），复用 `admin_assign_user_companies` RPC
- 修改公司后：新发票归属新公司；已提交/已审批的历史发票仍归属原公司（`invoices.company_id` 在创建时写入，不做自动迁移）
- 一次性数据修正：`sam.lu@bsctradingltd.top` 名下 18 张待审批发票从逸创奥(2)迁至逸创网络(1)，并补上该公司归属
- 数据修正脚本：`nas/sql/migration-v4.17-sam-lu-company-fix.sql`

---

## v4.16.2 (2026-07-31) - 当前版本 ✅
**改动**：成员可删除/批量删除自己的待提交、待审批、已驳回发票

### 关键变更
- 成员删除范围从 draft/rejected 扩展到 draft/rejected/pending（已通过仍锁定）
- 发票列表“删除选中”对成员开放，仅可删除自己名下可删除状态的发票
- 迁移脚本：`nas/sql/migration-v4.16.2-member-delete-pending.sql`

---

## v4.16.1 (2026-07-31)
**改动**：发票自动上传归属调整

### 关键变更
- 发票自动上传默认归属改为超级管理员 `sam.lu@ecsomni.com`，公司「逸创网络」(company_id=1)
- 其他自动上传监听（日常追踪/财务报表）不受影响

---

## v4.16 (2026-07-31) - 当前版本 ✅
**改动**：修复 OCR 识别后自动提交导致无法修改、识别率感知下降；成员可删除自己的草稿/驳回件；自动上传带归属

### 关键变更
- OCR 服务识别后只保存字段，不再把状态改为 pending；数据库同时禁止服务角色自动提交审批
- 前端 OCR 成功后同步用 SDK 保存字段；保存发票后弹窗确认「是否提交审批」
- 成员可删除自己的待提交/已驳回发票及其文件；已提交/已审批仍锁定
- 自动上传脚本：指定上传人账号/公司、按草稿入库、存储路径带公司前缀，保证成员可见可识别
- 迁移脚本：`nas/sql/migration-v4.16-ocr-draft-delete.sql`

---

## v4.15 (2026-07-31) - 当前版本 ✅
**改动**：新增独立「审批中心」，管理员仅本公司、超管全部公司

### 关键变更
- 新增审批中心页面：仅管理员/超管可见，展示待审批报销、申请人信息、公司、金额
- 支持勾选批量通过/批量驳回，实时汇总总金额与选中金额
- 数据权限：admin 仅可见/审批自己公司的发票、报表与文件；super_admin 可见全部公司；成员仍仅本人
- 迁移脚本：`nas/sql/migration-v4.15-approval-center.sql`

---

## v4.14 (2026-07-31) - 当前版本 ✅
**改动**：权限模型改为「成员仅见本人发票 + 提交审批 + 审批后锁定」

### 关键变更
- 成员只能看到自己上传的发票，不再按公司共享；Storage 文件同样只允许本人发票关联文件
- 新增状态流转：draft(待提交) → pending(待审批) → approved/rejected；成员保存后可点击「提交审批」
- 管理员只可审批 pending 发票；已审批发票对所有用户锁定（服务角色可纠错）
- 统计报表仅管理员/超管可见；成员不再看到公司级汇总
- 迁移脚本：`nas/sql/migration-v4.14-own-invoice-approval.sql`

---

## v4.13 (2026-07-31) - 当前版本 ✅
**改动**：修复「删除用户后重建仍无法登录」和「旧发票存储文件预览 400」

### 关键变更
- 删除用户改为 `admin_delete_user` RPC：同时删除 auth.users、auth.identities、profiles、user_companies，避免重建后沿用旧密码
- Storage 读取策略放行存量旧路径：对象文件名命中发票表且发票属于当前用户公司时允许读取，兼容无公司前缀的历史/自动上传文件
- 迁移脚本：`nas/sql/migration-v4.13-delete-storage-fix.sql`

---

## v4.12 (2026-07-31) - 当前版本 ✅
**改动**：修复用户创建不生效、普通用户越权查看全部数据/用户管理、普通用户可审批的问题，系统性收紧权限

### 关键变更
- 用户创建：改用 `admin_invite_user` RPC 直接创建 GoTrue 用户 + profile + 公司归属，返回一次性初始密码；修复 `/auth/v1/invite` 用 anon key 调用失败导致新用户不出现的问题
- 权限隔离：发票/报表/公司/档案/Storage 对象全部按「所属公司 + 管理员」收敛 RLS，普通用户不再能读取全部客户数据
- 角色固化：`handle_new_user` 触发器 + `ensure_my_profile` 只允许新建 member 档案，移除「无 profile 自动升为 super_admin」逻辑
- 审批限制：普通用户只有保存/上传/重新提交（rejected→pending）权限，通过/驳回仅管理员；删除/清理重复/类目管理同样仅管理员
- RPC 加固：`admin_create_profile`、`admin_update_user_status`、`admin_assign_user_companies`、`delete_invoice`、`insert_invoice`、`refresh_expense_report` 全部增加调用者权限/公司归属校验
- 安全修复：移除前端硬编码的 service key，bucket 改由 SQL 保证存在；Storage 对象删除改走管理员用户 token + RLS
- 前端修复：管理员切普通用户后导航残留（管理员入口/角色显示）会正确重置；普通用户公司下拉按所属公司加载；用户列表补回「所属公司」列
- 迁移脚本：`nas/sql/migration-v4.12-permissions.sql`（幂等，需对存量数据库执行）

---

## v4.7 (2026-07-29) - 当前版本 ✅
**改动**：添加财务类目功能，支持类目映射、筛选与汇总

### 关键变更
- schema/seed：`expense_categories` 新增 `financial_category` 列，含 mapping 种子数据
- 类目管理：显示/编辑/新增「财务类目」字段，可选：办公费、差旅费、招待费、福利费、通讯费
- 统计报表：新增「财务类目」筛选器，报表内显示财务类目汇总表
- 导出报表：Excel 含财务类目列 + 财务类目汇总 sheet
- 迁移脚本：`cloud/schema-financial-category.sql` 用于 Supabase 存量数据库迁移

---

## v4.6 (2026-07-29)
**改动**：修复 storage_path 无效值的 400 错误，增加前置校验

### 关键变更
- `loadPreview()` & `ocrInvoice()` in nas/index.html：加 `storage_path` 非空/长度校验，预览失败友好提示
- `editInvoice()` & `ocrInvoice()` in cloud/index.html：加 `hasFile` 条件判断，空路径时显示"暂无文件"而非发送 400 请求
- 统一前端文件预览/OCR/删除/导出等操作对 `storage_path` 的防御性校验

---

## v4.5 (2026-06-14)
**改动**：OCR 纯 stdlib（无 pip 依赖）+ 健康检查 + 错误传播

### 架构
- 5 容器：db / auth(gotrue) / rest(postgrest) / storage / ocr
- 密码登录（无邮件依赖）
- 使用 Docker named volumes（`ecs_pgdata_v17`）
- 无 nginx 网关（架构简化）

### 关键变更
- OCR 服务改用纯 Python stdlib，无需 pip install
- 健康检查增强：pg_isready + schema 确认双重检查
- 错误传播机制改进

---

## v3.4 — GoTrue 迁移修复
- init.sql 新增 `CREATE ROLE IF NOT EXISTS postgres`
- 修复 GoTrue 迁移 `role "postgres" does not exist`
- 6 容器：含 nginx 网关

## v3.3 — bind mount + ALTER ROLE
- 用 bind mount 替代 Docker named volumes
- 用 ALTER ROLE 强制设置所有角色密码

## v3.2 — supabase_admin + 完整 init.sql
- 从 nas-deploy 重建，硬编码密码

## v3.1 — 部署包初版（已废弃）
- init.sql 缺失 auth schema，GoTrue 迁移失败

## v3 — NAS Supabase 自托管（早期）
- 6 容器能跑但 magic link 邮件失败

## v2 — Docker 单容器
- 单容器 Flask 方案

## v1 — Supabase Cloud
- supabase.com 云服务

# v4.8 (2026-07-30)
 - 当前版本 ✅
**改动**：修复自动上传进程崩溃后不自启问题，增强系统稳定性机制

### 关键变更
- 自动上传守护进程崩溃后不自启 → plist 设置 KeepAlive=true，进程崩溃后自动重启
- 上传失败文件永不重试 → 新增 _failed/ 目录定期重试机制（每30分钟扫描一次）
- NAS 断连时无限空转浪费资源 → 新增连通性检查 + 指数退避等待（30s→600s）
- 无信号处理导致 PID 文件残留 → 注册 SIGTERM/SIGINT 信号处理器
- 前置启动检查确保已知状态 → 启动前检查 NAS 连通性，不可达时进入等待模式

### 相关文件
- `nas/scripts/auto_upload_invoices.py` — 主脚本增强
- `nas/scripts/com.ecs.auto-upload.plist` — plist 配置
- `nas/scripts/control.sh` — 控制脚本

---
