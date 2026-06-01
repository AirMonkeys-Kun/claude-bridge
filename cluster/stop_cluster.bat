@echo off
setlocal enabledelayedexpansion
set BASE=%~dp0
echo === Stopping V3 Cluster ===

:: ── Kill scheduler ──
for /f "skip=1 tokens=2 delims=,=" %%a in ('wmic process where "name='powershell.exe' and CommandLine like '%%scheduler.ps1%%'" get ProcessId /format:csv 2^>nul') do (
    taskkill /F /PID %%a 2>nul
    echo Killed scheduler (PID %%a)
)

:: ── Kill all workers by named pipe pattern ──
for /f "skip=1 tokens=2 delims=,=" %%a in ('wmic process where "name='powershell.exe' and CommandLine like '%%Cluster_Wkr_%%' and CommandLine like '%%worker.ps1%%'" get ProcessId /format:csv 2^>nul') do (
    taskkill /F /PID %%a 2>nul
    echo Killed cluster worker (PID %%a)
)

:: ── Also kill any orphaned runner.ps1 (V2 legacy) ──
for /f "skip=1 tokens=2 delims=,=" %%a in ('wmic process where "name='powershell.exe' and CommandLine like '%%runner.ps1%%'" get ProcessId /format:csv 2^>nul') do (
    taskkill /F /PID %%a 2>nul
    echo Killed legacy runner (PID %%a)
)

:: ── Clean up ──
echo Cleaning artifacts...
for %%d in (file registry process network system wsl) do (
    if exist "%BASE%%%d_bridge\.lock" del "%BASE%%%d_bridge\.lock"
    if exist "%BASE%%%d_bridge\.heartbeat" del "%BASE%%%d_bridge\.heartbeat"
    if exist "%BASE%%%d_bridge\wsl_*.bat" del /Q "%BASE%%%d_bridge\wsl_*.bat" 2>nul
    if exist "%BASE%%%d_bridge\wsl_*.txt" del /Q "%BASE%%%d_bridge\wsl_*.txt" 2>nul
)
if exist "%BASE%.lock" del "%BASE%.lock"
if exist "%BASE%.heartbeat" del "%BASE%.heartbeat"

echo === V3 Cluster Stopped ===
