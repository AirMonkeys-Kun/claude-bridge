@echo off
REM Claude Bridge V21 — One-Click Bootstrap
REM =============================================
REM This is the ONLY manual step needed.
REM After this, ALL updates are self-contained:
REM   - Self-upgrade: restarter.ps1 handles it
REM   - Crash recovery: guardian (BootTrigger) handles it
REM   - Guardian maintenance: watcher handles it
REM   - V2.2: worker_factory -DeployAll (single atomic pool write, no race)
REM   - V2.1: .NET Process.Start (reliable in S4U/headless), WriteAllText (no lock)
REM =============================================

cd /d "%~dp0"
echo.
echo ========================================
echo   Claude Bridge V21 — Bootstrap
echo ========================================
echo.

REM Step 1: Register Guardian v3 (BootTrigger + P365D = never expires)
echo [1/4] Register Guardian v3...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cluster\register_guardian_v3.ps1" -Force
echo.

REM Step 2: Deploy all workers atomically (V2.2: single DeployAll call, no pool race)
echo [2/4] Deploying all 14 workers (atomic pool write)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cluster\worker_factory.ps1" -DeployAll -BridgeBase "%~dp0"
echo.

REM Step 3: Start Watcher
echo [3/4] Starting watcher...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher\start_watcher_only.ps1"
echo.

REM Step 4: Verify
echo [4/4] Verification...
echo   Guardian task:
schtasks /Query /FO TABLE /NH /TN "BridgeGuardian-V3" 2>nul
echo.
echo   Done! The bridge is now running and self-sustaining.
echo   Future updates require ZERO manual steps.
echo.
echo ========================================
pause
