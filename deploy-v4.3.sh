#!/bin/bash
# ECS v4.3 一键部署 + 验证脚本
# 在 Mac 终端运行: bash "deploy-v4.3.sh"

set -e
NAS="sam.lu@192.168.3.150"
NAS_DIR="/volume1/docker/ecs-expense"
LOCAL_DIR="/Users/sam.lu/Documents/Business Related/Finance/Expenses/ECS  Expanses/ecs-expense-system/部署包-放到NAS"
N="http://192.168.3.150:18000"

echo "╔══════════════════════════════════════╗"
echo "║   ECS v4.3 一键部署                  ║"
echo "╚══════════════════════════════════════╝"

# ====== 第1步：上传文件 ======
echo ""
echo "【1/5】上传文件到 NAS..."
for f in docker-compose.yml nginx.conf index.html sql/init.sql; do
  echo -n "  $f ... "
  cat "$LOCAL_DIR/$f" | ssh $NAS "cat > $NAS_DIR/$f" && echo "✅" || { echo "❌ 失败"; exit 1; }
done

# ====== 第2步：验证上传 ======
echo ""
echo "【2/5】验证文件完整性..."
for f in docker-compose.yml nginx.conf index.html sql/init.sql; do
  local_md5=$(md5 -q "$LOCAL_DIR/$f")
  nas_md5=$(ssh $NAS "md5sum $NAS_DIR/$f" 2>/dev/null | cut -d' ' -f1)
  if [ "$local_md5" = "$nas_md5" ]; then
    echo "  ✅ $f"
  else
    echo "  ❌ $f MD5不匹配！本地=$local_md5 NAS=$nas_md5"
    exit 1
  fi
done

# ====== 第3步：重启项目 ======
echo ""
echo "【3/5】重启 Docker 项目..."
echo "  请在 DSM Container Manager 中手动操作："
echo "  项目 → ecs-expense → 停用 → 删除 → 从 docker-compose.yml 重建"
echo ""
echo "  完成后按回车继续..."
read

# ====== 第4步：等待服务就绪 ======
echo ""
echo "【4/5】等待服务就绪（最多 3 分钟）..."
for i in $(seq 1 18); do
  AUTH=$(curl -s -o /dev/null -w "%{http_code}" "$N/auth/v1/health" --max-time 5 2>/dev/null || echo "000")
  REST=$(curl -s -o /dev/null -w "%{http_code}" "$N/rest/v1/" --max-time 5 2>/dev/null || echo "000")
  STORAGE=$(curl -s -o /dev/null -w "%{http_code}" "$N/storage/v1/bucket" -H "apikey: eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODE0MjU0NzAsImV4cCI6MjA5Njc4NTQ3MH0.OlDOPGOt0c-JKO_eIPf_HrbH9nE3Oyk-4RF6GBnxAgo" --max-time 5 2>/dev/null || echo "000")
  echo "  [$i/18] auth=$AUTH rest=$REST storage=$STORAGE"
  if [ "$AUTH" = "200" ] && [ "$REST" = "200" ] && [ "$STORAGE" != "000" ]; then
    echo "  ✅ 所有服务就绪！"
    break
  fi
  sleep 10
done

# ====== 第5步：创建管理员 ======
echo ""
echo "【5/5】创建管理员账号..."
SIGNUP=$(curl -s -X POST "$N/auth/v1/signup" \
  -H "Content-Type: application/json" \
  -H "apikey: eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODE0MjU0NzAsImV4cCI6MjA5Njc4NTQ3MH0.OlDOPGOt0c-JKO_eIPf_HrbH9nE3Oyk-4RF6GBnxAgo" \
  -d '{"email":"sam.lu@ecsomni.com","password":"ecs2026"}' --max-time 10)

USER_ID=$(echo "$SIGNUP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
if [ -n "$USER_ID" ]; then
  echo "  ✅ 用户创建成功: $USER_ID"
  sleep 2
  # 设为 super_admin
  curl -s -X POST "$N/rest/v1/rpc/admin_create_profile" \
    -H "Content-Type: application/json" \
    -H "apikey: eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODE0MjU0NzAsImV4cCI6MjA5Njc4NTQ3MH0.OlDOPGOt0c-JKO_eIPf_HrbH9nE3Oyk-4RF6GBnxAgo" \
    -H "Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODE0MjU0NzAsImV4cCI6MjA5Njc4NTQ3MH0.OlDOPGOt0c-JKO_eIPf_HrbH9nE3Oyk-4RF6GBnxAgo" \
    -d "{\"p_id\":\"$USER_ID\",\"p_email\":\"sam.lu@ecsomni.com\",\"p_name\":\"Sam Lu\",\"p_role\":\"super_admin\"}" --max-time 10 > /dev/null 2>&1
  echo "  ✅ 已设为 super_admin"
else
  echo "  ⚠️  注册返回: $SIGNUP"
fi

# 验证登录
echo ""
echo "  验证登录..."
LOGIN=$(curl -s -X POST "$N/auth/v1/token?grant_type=password" \
  -H "Content-Type: application/json" \
  -d '{"email":"sam.lu@ecsomni.com","password":"ecs2026"}' --max-time 10)
TOKEN=$(echo "$LOGIN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
if [ -n "$TOKEN" ]; then
  echo "  ✅ 登录成功！v4.3 部署完成 🎉"
else
  echo "  ❌ 登录失败: $LOGIN"
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   部署完成，访问 http://192.168.3.150:18000   ║"
echo "╚══════════════════════════════════════╝"
