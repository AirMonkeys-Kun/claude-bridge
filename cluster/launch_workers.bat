@echo off
set BASE=%~dp0
echo === Launching V3 Cluster ===

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
for %%d in (file registry process network system wsl user) do (
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
copy /Y "%BASE%file_bridge\worker.ps1" "%BASE%registry_bridge\worker.ps1" >nul
copy /Y "%BASE%file_bridge\worker.ps1" "%BASE%process_bridge\worker.ps1" >nul
copy /Y "%BASE%file_bridge\worker.ps1" "%BASE%network_bridge\worker.ps1" >nul
copy /Y "%BASE%file_bridge\worker.ps1" "%BASE%system_bridge\worker.ps1" >nul

:: ── Reset queues to V3 format ──
echo {"v":3,"state":"idle"} > "%BASE%file_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%registry_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%process_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%network_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%system_bridge\queue.txt"
echo {"v":3,"state":"idle"} > "%BASE%wsl_bridge\queue.txt"

:: ── Launch workers ──
echo Launching 7 workers + scheduler...
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%file_bridge\worker.ps1" -WorkerDir "%BASE%file_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%registry_bridge\worker.ps1" -WorkerDir "%BASE%registry_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%process_bridge\worker.ps1" -WorkerDir "%BASE%process_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%network_bridge\worker.ps1" -WorkerDir "%BASE%network_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%system_bridge\worker.ps1" -WorkerDir "%BASE%system_bridge"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%wsl_bridge\worker.ps1" -WorkerDir "%BASE%wsl_bridge"
:: user_bridge: run via token duplication (SYSTEM → USER context)
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%user_bridge\runner.ps1"
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BASE%scheduler.ps1" -ClusterDir "%BASE%"
echo All V4 workers (7) + scheduler launched
