#!/bin/bash
# ECS v4.4 一键部署到 NAS
set -e
NAS="sam.lu@192.168.3.150"
NAS_PATH="/volume1/docker/ecs-expense"
LOCAL_BASE="/Users/sam.lu/Documents/Business Related/Finance/Expenses/ECS  Expanses/ecs-expense-system/部署包-放到NAS"

echo "╔══════════════════════════════════════════════╗"
echo "║   ECS v4.4 一键部署                          ║"
echo "╚══════════════════════════════════════════════╝"

# 1. 确保 NAS 目录结构存在
echo ""
echo "📁 创建 NAS 目录..."
ssh "$NAS" "mkdir -p $NAS_PATH/sql $NAS_PATH/ocr-service" 2>/dev/null || true

# 2. 上传所有文件
echo "📤 上传配置文件..."
cat "$LOCAL_BASE/docker-compose.yml" | ssh "$NAS" "cat > $NAS_PATH/docker-compose.yml"
cat "$LOCAL_BASE/nginx.conf"        | ssh "$NAS" "cat > $NAS_PATH/nginx.conf"
cat "$LOCAL_BASE/index.html"        | ssh "$NAS" "cat > $NAS_PATH/index.html"
cat "$LOCAL_BASE/sql/init.sql"      | ssh "$NAS" "cat > $NAS_PATH/sql/init.sql"
cat "$LOCAL_BASE/ocr-service/app.py"| ssh "$NAS" "cat > $NAS_PATH/ocr-service/app.py"

echo "✅ 5 个文件上传完成"

# 3. 验证文件完整性
echo ""
echo "🔍 验证 NAS 文件..."
echo -n "  docker-compose.yml: "
ssh "$NAS" "head -1 $NAS_PATH/docker-compose.yml"
echo -n "  nginx.conf: "
ssh "$NAS" "head -1 $NAS_PATH/nginx.conf"
echo -n "  index.html: "
ssh "$NAS" "head -2 $NAS_PATH/index.html | tail -1"
echo -n "  init.sql: "
ssh "$NAS" "head -1 $NAS_PATH/sql/init.sql"
echo -n "  ocr/app.py: "
ssh "$NAS" "head -1 $NAS_PATH/ocr-service/app.py"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   上传完成！请在 DSM 中执行：               ║"
echo "║                                              ║"
echo "║   Container Manager → 项目                  ║"
echo "║   → 选中 ecs-expense-v4 → 清除              ║"
echo "║   → 新增 → 从 docker-compose.yml            ║"
echo "║   → 路径: /volume1/docker/ecs-expense       ║"
echo "║                                              ║"
echo "║   等待 2 分钟后运行验收测试：               ║"
echo "║   bash test-deploy.sh                       ║"
echo "╚══════════════════════════════════════════════╝"
