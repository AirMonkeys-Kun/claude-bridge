@echo off
title Claude Bridge Boot Launcher (V4)
cd /d "%~dp0"

:: Start the V4 cluster (scheduler + 7 workers)
echo === Claude Bridge Boot Launcher (V4) ===
echo [%date% %time%] Starting V4 cluster >> "%~dp0cluster\launch.log"
call "%~dp0cluster\launch_workers.bat"

:: V4 cluster is the primary interface. The old watcher.ps1 is no longer needed.
:: Use V4 worker queues directly:
::   file_bridge:    cluster\file_bridge\queue.txt  (SYSTEM context)
::   user_bridge:    cluster\user_bridge\queue.txt   (USER context)
::   system_bridge:  cluster\system_bridge\queue.txt  (SYSTEM systems operations)

:: Register guardian scheduled task if not already present (runs every 5 min)
schtasks /Query /TN BridgeGuardian-V4 >nul 2>&1
if errorlevel 1 (
    echo [%date% %time%] Registering V4 guardian task >> "%~dp0cluster\launch.log"
    call "%~dp0cluster\register_guardian.bat"
)

echo Boot launcher completed
