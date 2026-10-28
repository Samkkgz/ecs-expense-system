#!/usr/bin/env python3
"""ECS 发票自动上传 — 心跳看门狗

由 launchd com.ecs.auto-upload-watchdog 每 5 分钟调用：
  1. 进程未运行 → 重启监听
  2. 心跳超过 300 秒未更新 → 判定假死，强制重启
日志: /tmp/auto_upload_watchdog.log
"""

import os
import subprocess
import time

PID_FILE = "/tmp/auto_upload_invoices.pid"
HEARTBEAT_FILE = "/tmp/auto_upload_invoices.heartbeat"
WATCHDOG_LOG = "/tmp/auto_upload_watchdog.log"
PLIST_LABEL = "com.ecs.auto-upload"
STALE_SECONDS = int(os.environ.get("WATCHDOG_STALE_SECONDS", "300"))


def log(msg):
    with open(WATCHDOG_LOG, "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%m-%d %H:%M:%S')} [watchdog] {msg}\n")


def pid_alive(pid):
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def restart_watcher():
    log(f"重启监听: launchctl kickstart -k gui/{os.getuid()}/{PLIST_LABEL}")
    try:
        subprocess.run(
            ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{PLIST_LABEL}"],
            check=True,
            stdout=open(WATCHDOG_LOG, "a"),
            stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError:
        control_sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "control.sh")
        subprocess.run(["bash", control_sh, "restart"], stdout=open(WATCHDOG_LOG, "a"), stderr=subprocess.STDOUT)


def main():
    try:
        pid = int(open(PID_FILE, encoding="ascii").read().strip())
    except (OSError, ValueError):
        pid = 0

    if not pid_alive(pid):
        log(f"进程未运行（PID: {pid or '无'}），执行重启")
        restart_watcher()
        return

    try:
        last = float(open(HEARTBEAT_FILE, encoding="ascii").read().strip())
    except (OSError, ValueError):
        log("心跳文件缺失，判定异常，执行重启")
        restart_watcher()
        return

    age = int(time.time() - last)
    if age > STALE_SECONDS:
        log(f"心跳超时 {age}s > {STALE_SECONDS}s，判定假死，执行重启")
        restart_watcher()
        return

    log(f"检查正常 (PID: {pid}, 心跳 {age}s)")


if __name__ == "__main__":
    main()
