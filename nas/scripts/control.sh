#!/bin/bash
# ============================================
# ECS 发票自动上传 — 开关控制脚本
# 用法: bash control.sh {start|stop|status|restart|log}
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/auto_upload_invoices.py"
PID_FILE="/tmp/auto_upload_invoices.pid"
LOG_FILE="/tmp/auto_upload_invoices.log"

# 颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

check_pid() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

case "${1:-status}" in
    start)
        if check_pid >/dev/null; then
            echo -e "${YELLOW}⚠ 已在运行中 (PID: $(cat $PID_FILE))${NC}"
            exit 0
        fi
        echo -e "${GREEN}▶ 启动 ECS 发票自动上传...${NC}"
        python3 "$MAIN_SCRIPT" --daemon
        sleep 1
        if check_pid >/dev/null; then
            echo -e "${GREEN}✅ 已启动 (PID: $(cat $PID_FILE))${NC}"
        else
            echo -e "${RED}❌ 启动失败，请检查日志: tail -20 $LOG_FILE${NC}"
        fi
        ;;
    stop)
        _pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            echo -e "${YELLOW}⏹ 停止 ECS 发票自动上传 (PID: $_pid)...${NC}"
            kill "$_pid" 2>/dev/null
            sleep 1
            if kill -0 "$_pid" 2>/dev/null; then
                kill -9 "$_pid" 2>/dev/null
            fi
            rm -f "$PID_FILE"
            echo -e "${GREEN}✅ 已停止${NC}"
        else
            rm -f "$PID_FILE"
            echo -e "${YELLOW}⚠ 未在运行${NC}"
        fi
        ;;
    status)
        _pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            echo -e "${GREEN}✅ 运行中 (PID: $_pid)${NC}"
            echo "   日志: $LOG_FILE"
            echo "   停止: bash $0 stop"
        else
            echo -e "${YELLOW}⚠ 未运行${NC}"
            echo "   启动: bash $0 start"
        fi
        ;;
    restart)
        bash "$0" stop
        sleep 1
        bash "$0" start
        ;;
    watchdog)
        python3 "$SCRIPT_DIR/watchdog.py"
        ;;
    log)
        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            echo -e "${YELLOW}⚠ 日志文件不存在${NC}"
        fi
        ;;
    enable-auto)
        # 安装 LaunchAgent 实现登录时自启动（监听 + 看门狗）
        PLIST_DST="$HOME/Library/LaunchAgents/com.ecs.auto-upload.plist"
        WATCHDOG_PLIST_DST="$HOME/Library/LaunchAgents/com.ecs.auto-upload-watchdog.plist"
        mkdir -p "$HOME/Library/LaunchAgents"
        cat > "$PLIST_DST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ecs.auto-upload</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${MAIN_SCRIPT}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
</dict>
</plist>
PLIST_EOF
        cat > "$WATCHDOG_PLIST_DST" << WATCHDOG_PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ecs.auto-upload-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${SCRIPT_DIR}/watchdog.py</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/auto_upload_watchdog.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/auto_upload_watchdog.log</string>
</dict>
</plist>
WATCHDOG_PLIST_EOF
        launchctl load "$PLIST_DST" 2>/dev/null || true
        launchctl load "$WATCHDOG_PLIST_DST" 2>/dev/null || true
        echo -e "${GREEN}✅ 已设置登录时自启动（监听 + 看门狗）${NC}"
        echo "   取消: bash $0 disable-auto"
        ;;
    disable-auto)
        PLIST_DST="$HOME/Library/LaunchAgents/com.ecs.auto-upload.plist"
        WATCHDOG_PLIST_DST="$HOME/Library/LaunchAgents/com.ecs.auto-upload-watchdog.plist"
        launchctl unload "$PLIST_DST" 2>/dev/null || true
        launchctl unload "$WATCHDOG_PLIST_DST" 2>/dev/null || true
        rm -f "$PLIST_DST" "$WATCHDOG_PLIST_DST"
        echo -e "${GREEN}✅ 已取消登录时自启动（含看门狗）${NC}"
        ;;
    *)
        echo "ECS 发票自动上传 — 控制脚本"
        echo ""
        echo "用法: bash $0 {command}"
        echo ""
        echo "命令:"
        echo "  start         启动（后台运行）"
        echo "  stop          停止"
        echo "  status        查看运行状态"
        echo "  restart       重启"
        echo "  watchdog      手动执行一次看门狗检查"
        echo "  log           实时查看日志 (Ctrl+C 退出)"
        echo "  enable-auto   设置 Mac 登录时自启动"
        echo "  disable-auto  取消登录时自启动"
        ;;
esac
