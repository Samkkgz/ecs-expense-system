#!/bin/bash
# ECS 发票自动上传 — 快捷开关
# 在项目根目录直接使用: bash ecs-upload.sh {on|off|status|log}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-status}" in
    on|start)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" start
        ;;
    off|stop)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" stop
        ;;
    status)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" status
        ;;
    restart)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" restart
        ;;
    log)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" log
        ;;
    auto-on)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" enable-auto
        ;;
    auto-off)
        bash "${SCRIPT_DIR}/nas/scripts/control.sh" disable-auto
        ;;
    *)
        echo "ECS 发票自动上传 — 快捷开关"
        echo ""
        echo "用法: bash ecs-upload.sh {command}"
        echo ""
        echo "  开关控制:"
        echo "    on / start        启动监听"
        echo "    off / stop        停止监听"
        echo "    status            查看运行状态"
        echo "    restart           重启"
        echo "    log               实时日志"
        echo ""
        echo "  开机自启:"
        echo "    auto-on           设置开机自启动"
        echo "    auto-off          取消开机自启动"
        ;;
esac
