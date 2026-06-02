@echo off
title Claude Bridge V2 Guardian
cd /d "%~dp0"

set CLUSTER_DIR=%~dp0
set WATCHDOG_LOG=%~dp0v2_guardian.log
set MAX_AGE_SECONDS=120

:: Check all 6 worker heartbeats with one PowerShell call
powershell -NoProfile -Command ^
  "$base='%~dp0';" ^
  "$dirs=@('file_bridge','registry_bridge','process_bridge','network_bridge','system_bridge','wsl_bridge');" ^
  "$max=120;" ^
  "$stale=@();" ^
  "foreach ($d in $dirs) {" ^
    "$hbFile=Join-Path $base \"$d\.watcher_heartbeat\";" ^
    "$lockFile=Join-Path $base \"$d\.watcher.lock\";" ^
    "if (Test-Path $hbFile) {" ^
      "$hb=[System.IO.File]::ReadAllText($hbFile,[System.Text.UTF8Encoding]::new($false)).Trim();" ^
      "try { $hbT=[datetime]::ParseExact($hb.Substring(0,19),'yyyy-MM-dd HH:mm:ss',$null); $age=[int](((Get-Date)-$hbT).TotalSeconds); if ($age -gt $max) { $stale+=$d } } catch { $stale+=$d }" ^
    "} else { $stale+=$d }" ^
  "};" ^
  "if ($stale.Count -gt 0) { exit 1 } else { exit 0 }"
if %ERRORLEVEL% EQU 0 goto :eof

:: Heartbeat stale — log and restart
echo [%date% %time%] V2 Guardian: Stale workers: restarting... >> %WATCHDOG_LOG%

:: Kill stale workers via lock files
powershell -NoProfile -Command ^
  "$base='%~dp0';" ^
  "$dirs=@('file_bridge','registry_bridge','process_bridge','network_bridge','system_bridge','wsl_bridge');" ^
  "foreach ($d in $dirs) { $f=Join-Path $base \"$d\.watcher.lock\"; if (Test-Path $f) { try { $p=[int]([System.IO.File]::ReadAllText($f,[System.Text.UTF8Encoding]::new($false)).Trim()); Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {} } }" ^
  "echo 'Stale workers killed'"
timeout /t 2 /nobreak >nul

:: Reset queues
powershell -NoProfile -Command ^
  "$idle='{\"state\":\"idle\",\"cmd_id\":\"\",\"command\":\"\",\"type\":\"\"}';" ^
  "$dirs=@('file_bridge','registry_bridge','process_bridge','network_bridge','system_bridge','wsl_bridge');" ^
  "foreach ($d in $dirs) { $q=Join-Path '%~dp0' \"$d\queue.txt\"; [System.IO.File]::WriteAllText($q,$idle,[System.Text.UTF8Encoding]::new($false)) }"
echo Queues reset

:: Start workers via Scheduled Tasks
echo Starting BridgeCluster tasks...
powershell -NoProfile -Command ^
  "$tasks=@('BridgeCluster-file','BridgeCluster-registry','BridgeCluster-process','BridgeCluster-network','BridgeCluster-system','BridgeCluster-wsl');" ^
  "foreach ($t in $tasks) { try { Start-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {} }"

:: Also try _bridge suffixed tasks
powershell -NoProfile -Command ^
  "$tasks=@('BridgeCluster-file_bridge','BridgeCluster-registry_bridge','BridgeCluster-process_bridge','BridgeCluster-network_bridge','BridgeCluster-system_bridge','BridgeCluster-wsl_bridge');" ^
  "foreach ($t in $tasks) { try { Start-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue } catch {} }"

echo [%date% %time%] V2 Guardian: Workers started >> %WATCHDOG_LOG%
