@echo off
title Claude Bridge Guardian (Scheduled Task)
cd /d "%~dp0"

:: Check heartbeat - if stale or missing, restart everything
set HEARTBEAT_FILE=.watcher_heartbeat
set MAX_AGE_SECONDS=60

:: If heartbeat file doesn't exist, start immediately
if not exist "%HEARTBEAT_FILE%" goto start_bridge

:: Check heartbeat age using PowerShell
powershell -NoProfile -Command ^
  "$hb='%~dp0.watcher_heartbeat';" ^
  "$age=[int](((get-date)-(gi $hb).LastWriteTime).TotalSeconds);" ^
  "if ($age -gt %MAX_AGE_SECONDS%) { exit 1 } else { exit 0 }"
if %ERRORLEVEL% EQU 0 goto :eof

:start_bridge
echo [%date% %time%] Guardian: Bridge heartbeat stale or missing, starting... >> watchdog.log

:: Kill old watchers first
powershell -NoProfile -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*watcher*ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

:: Start fresh watcher (hidden)
start "" /B powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0watcher.ps1"
echo [%date% %time%] Guardian: Watcher started via scheduled task >> watchdog.log
