@echo off
title Claude Bridge Boot Launcher
cd /d "%~dp0"

:: Start the V3 cluster (scheduler + 6 workers)
echo === Claude Bridge Boot Launcher ===
echo [%date% %time%] Starting V3 cluster >> "%~dp0cluster\scheduler.log"
call "%~dp0cluster\launch_workers.bat"

:: Start the external file watcher bridge
echo [%date% %time%] Starting file watcher >> "%~dp0watcher\watcher.log"
start /B /MIN powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0watcher\watcher.ps1"

:: Clean orphan watcher dirs from legacy versions
for /d %%d in ("%~dp0cluster\*_bridge_bridge") do (
    rmdir /S /Q "%%d" 2>nul
)

echo Boot launcher completed
