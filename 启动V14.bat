@echo off
title V14 Bridge Starter
cd /d "%~dp0"
echo [1] Killing stale watcher by lock file...
for /F %%p in ('type "%~dp0watcher\.watcher.lock" 2^>nul') do taskkill /F /PID %%p 2>nul >nul
del /Q "%~dp0watcher\.watcher.lock" 2>nul
del /Q "%~dp0watcher\.watcher_heartbeat" 2>nul
echo [2] Starting V14 watcher...
start "" /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher\watcher.ps1"
echo [3] Waiting for heartbeat...
timeout /T 5 /NOBREAK >nul
if exist "%~dp0watcher\.watcher_heartbeat" (
    echo [OK] Watcher is alive!
) else (
    echo [FAIL] No heartbeat found.
)
echo.
echo You can close this window now.
pause
