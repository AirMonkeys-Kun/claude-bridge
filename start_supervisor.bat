@echo off
rem ============================================================
rem  Claude Bridge Supervisor 启动器
rem  用途: 保持桥健康（watcher/agent/worker 池 死了自动接管、
rem        孤儿自动回收、手动关闭走 .manual_stop）
rem  用法: 双击本文件 或 命令行运行
rem  关闭: 在 watcher\.manual_stop 建文件即可停止托管
rem ============================================================
cd /d "D:\zebbingo\tools\claude-bridge"
rem 单实例锁由 supervisor 内部用 Windows Mutex 保证，重复启动会自动退出多余的
start "ClaudeBridgeSupervisor" /min "C:\Program Files\Python313\python.exe" bridge_supervisor.py
echo.
echo Supervisor 已启动（最小化窗口）。查看日志: bridge_supervisor.log
echo 关闭托管: 在 watcher 目录建 .manual_stop 文件
pause
