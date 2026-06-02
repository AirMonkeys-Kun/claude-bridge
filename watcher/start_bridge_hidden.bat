@echo off
cd /d "%~dp0"
start /B /MIN powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0watcher.ps1"
echo Background watcher started (PID unknown)
echo Check watcher.log for status
timeout /t 3 >nul
type watcher.log 2>nul || echo "(no log yet)"
pause
