#!/bin/bash
# ECS v4.4 - 管理员账户设置
# 用法: 在 NAS 上运行 docker exec -i ecs-db psql -U supabase_admin -d postgres < setup-admin.sh
# 或: 在 Mac 上运行 bash setup-admin.sh 通过 SSH 远程执行

N="http://192.168.3.150:18000"
SERVICE_KEY="eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODE0MjU0NzAsImV4cCI6MjA5Njc4NTQ3MH0.6G3AYHeOucFMTIPnsFn4558OBy9x4mbD3_dT0VBGHJs"

echo "=== ECS v4.4 管理员设置 ==="

# 通过 GoTrue API 注册/登录管理员
echo "1. 注册管理员账户..."
# 先 signup
curl -s -X POST "$N/auth/v1/signup" -H "Content-Type: application/json" \
  -d '{"email":"sam.lu@ecsomni.com","password":"ecs2026"}' --max-time 10 > /dev/null 2>&1
# 再登录获取 token
RESP=$(curl -s -X POST "$N/auth/v1/token?grant_type=password" \
  -H "Content-Type: application/json" \
  -d '{"email":"sam.lu@ecsomni.com","password":"ecs2026"}' --max-time 10)

TOKEN=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
USER_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('user',{}).get('id',''))" 2>/dev/null)

if [ -n "$TOKEN" ]; then
  echo "   ✅ 管理员已注册/登录成功"
  echo "   User ID: $USER_ID"

  # 更新 profile 为 super_admin
  echo "2. 设置 super_admin 权限..."
  PROFILE_RESP=$(curl -s "$N/rest/v1/profiles?id=eq.$USER_ID" \
    -H "apikey: $SERVICE_KEY" \
    -H "Authorization: Bearer $TOKEN" --max-time 10)
  
  if echo "$PROFILE_RESP" | grep -q '"id"'; then
    # 已存在，更新
    curl -s -X PATCH "$N/rest/v1/profiles?id=eq.$USER_ID" \
      -H "apikey: $SERVICE_KEY" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"role":"super_admin"}' --max-time 10
  else
    # 新建
    curl -s -X POST "$N/rest/v1/rpc/admin_create_profile" \
      -H "apikey: $SERVICE_KEY" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"p_id\":\"$USER_ID\",\"p_email\":\"sam.lu@ecsomni.com\",\"p_name\":\"管理员\",\"p_role\":\"super_admin\"}" --max-time 10
  fi
  echo "   ✅ super_admin 权限已设置"

  # 创建 storage bucket
  echo "3. 创建 invoices bucket..."
  curl -s -X POST "$N/storage/v1/bucket" \
    -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d '{"name":"invoices","public":false,"file_size_limit":52428800}' --max-time 10
  echo ""
  echo "   ✅ bucket 检查完成"

else
  echo "   ❌ 注册失败: $RESP"
fi

echo ""
echo "=== 管理员设置完成 ==="
echo "访问地址: $N"
echo "邮箱: sam.lu@ecsomni.com"
echo "密码: ecs2026"
