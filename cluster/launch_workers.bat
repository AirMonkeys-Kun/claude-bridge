@echo off
set BASE=%~dp0
echo === Launching Cluster Bridges ===
echo [DEPRECATED] 请改用 watcher/watcher.ps1 作为主要执行入口
echo              network_bridge 和 registry_bridge 已禁用（从未被使用）
echo              master_scheduler.ps1 已废弃（master_queue.txt 从未接收过命令）

:: ── Kill any stale V2/V3 processes ──
echo Killing stale cluster processes...
for /f "skip=1 tokens=2 delims=,=" %%a in ('wmic process where "name='powershell.exe' and CommandLine like '%%scheduler.ps1%%'" get ProcessId /format:csv 2^>nul') do (
    taskkill /F /PID %%a 2>nul
    echo Killed old scheduler (PID %%a)
)
for /f "skip=1 tokens=2 delims=,=" %%a in ('wmic process where "name='powershell.exe' and CommandLine like '%%Cluster_Wkr_%%' and CommandLine like '%%worker.ps1%%'" get ProcessId /format:csv 2^>nul') do (
    taskkill /F /PID %%a 2>nul
    echo Killed old worker (PID %%a)
)
timeout /t 1 /nobreak >nul

:: ── Clean all stale artifacts ──
echo Cleaning artifacts...
for %%d in (file process system wsl user) do (
    if exist "%BASE%%%d_bridge\.lock" del "%BASE%%%d_bridge\.lock"
    if exist "%BASE%%%d_bridge\.heartbeat" del "%BASE%%%d_bridge\.heartbeat"
    if exist "%BASE%%%d_bridge\r_*.json" del /Q "%BASE%%%d_bridge\r_*.json" 2>nul
    if exist "%BASE%%%d_bridge\wsl_*.bat" del /Q "%BASE%%%d_bridge\wsl_*.bat" 2>nul
    if exist "%BASE%%%d_bridge\wsl_*.txt" del /Q "%BASE%%%d_bridge\wsl_*.txt" 2>nul
)
if exist "%BASE%.lock" del "%BASE%.lock"
if exist "%BASE%.heartbeat" del "%BASE%.heartbeat"
if exist "%BASE%r_*.json" del /Q "%BASE%r_*.json" 2>nul
if exist "%BASE%master_queue.txt" del "%BASE%master_queue.txt"

:: ── Ensure standard workers use V3 script (wsl_bridge has custom WSL handler) ──
copy /Y "%BASE%file_bridge\worker.ps1" "%BASE%process_bridge\worker.ps1" >nul
copy /Y "%BASE%file_bridge\worker.ps1" "%BASE%system_bridge\worker.ps1" >nul

:: ── Reset queues to V3 format ──
echo {"v":3,"state":"idle"} > "%BASE%file_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%process_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%system_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%wsl_bridge\queue.txt"

:: ── Launch workers ──
echo Launching active workers...
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%file_bridge\worker.ps1" -WorkerDir "%BASE%file_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%process_bridge\worker.ps1" -WorkerDir "%BASE%process_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%system_bridge\worker.ps1" -WorkerDir "%BASE%system_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%wsl_bridge\worker.ps1" -WorkerDir "%BASE%wsl_bridge"
:: user_bridge: run via token duplication (SYSTEM → USER context)
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%user_bridge\runner.ps1"
echo Workers launched (file, process, system, wsl, user)
