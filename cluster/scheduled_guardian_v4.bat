@echo off
title Claude Bridge V4 Guardian (Scheduled Task)
cd /d "%~dp0"

set CLUSTER_DIR=%~dp0
set WATCHDOG_LOG=%~dp0guardian.log
set MAX_AGE_SECONDS=90

:: Check active heartbeats with one PowerShell call
:: registry_bridge & network_bridge were intentionally removed in V3 migration
:: (operations covered by V4 typed workers) — see commit 9d8e9a3
powershell -NoProfile -Command ^
  "$base='%~dp0';" ^
  "$dirs=@('file_bridge','process_bridge','system_bridge','wsl_bridge','user_bridge','.');" ^
  "$max=%MAX_AGE_SECONDS%;" ^
  "$stale=@();" ^
  "foreach ($d in $dirs) {" ^
    "$hbFile=Join-Path $base \"$d\.heartbeat\";" ^
    "if (Test-Path $hbFile) {" ^
      "$hb=(Get-Item $hbFile).LastWriteTime;" ^
      "$age=[int](((Get-Date)-$hb).TotalSeconds);" ^
      "if ($age -gt $max) { $stale+=$d }" ^
    "} else { $stale+=$d }" ^
  "};" ^
  "if ($stale.Count -gt 0) { exit 1 } else { exit 0 }"
if %ERRORLEVEL% EQU 0 goto :eof

:: Heartbeat stale — log and restart
echo [%date% %time%] Guardian: V4 cluster heartbeat(s) stale, restarting... >> %WATCHDOG_LOG%

:: Kill V3 bridge workers + scheduler only (NOT V4 typed workers — they're managed by watcher/factory)
powershell -NoProfile -Command ^
  "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { " ^
    "$_.CommandLine -like '*_bridge\worker.ps1*' -or $_.CommandLine -like '*scheduler.ps1*'" ^
  "} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ('Killed PID='+$_.ProcessId) }"
timeout /t 2 /nobreak >nul

:: Clean stale artifacts
for %%d in (file_bridge process_bridge system_bridge wsl_bridge user_bridge) do (
    if exist "%%d\.lock" del "%%d\.lock"
    if exist "%%d\.heartbeat" del "%%d\.heartbeat"
    if exist "%%d\r_*.json" del /Q "%%d\r_*.json" 2>nul
)
if exist ".heartbeat" del ".heartbeat"
if exist "r_*.json" del /Q "r_*.json" 2>nul

:: Launch V4 cluster
echo [%date% %time%] Guardian: Launching V4 cluster... >> %WATCHDOG_LOG%
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0file_bridge\worker.ps1" -WorkerDir "%~dp0file_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0process_bridge\worker.ps1" -WorkerDir "%~dp0process_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0system_bridge\worker.ps1" -WorkerDir "%~dp0system_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0wsl_bridge\worker.ps1" -WorkerDir "%~dp0wsl_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0user_bridge\runner.ps1"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scheduler.ps1" -ClusterDir "%~dp0"

echo [%date% %time%] Guardian: V4 cluster launched >> %WATCHDOG_LOG%
