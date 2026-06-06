@echo off
REM Quick restart — kills old watcher, starts new one
REM Triggered by Claude Bridge management

cd /d "%~dp0"

REM Kill old watchers
for /f "tokens=2" %%p in ('tasklist /fi "imagename eq powershell.exe" /fo csv /nh 2^>nul ^| findstr /i "watcher"') do (
    taskkill /pid %%p /f >nul 2>&1
)

REM Clean stale files
del /q ".watcher.lock" 2>nul
del /q ".watcher_heartbeat" 2>nul
del /q "r_*.json" 2>nul

REM Start fresh watcher
start /B /MIN powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0watcher.ps1"

REM Wait for heartbeat
timeout /t 5 >nul
if exist ".watcher_heartbeat" (
    echo [OK] Watcher restarted successfully
    type ".watcher_heartbeat"
) else (
    echo [WARN] No heartbeat yet — check watcher.log
)
