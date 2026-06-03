@echo off
title Claude Bridge - Restart
cd /d "%~dp0"
echo.
echo ========================================
echo   Claude Bridge V14 - One Click Restart
echo ========================================
echo.
echo Starting V14 watcher + workers...
echo Log: restart_output.log
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher\start_v14_now.ps1" > restart_output.log 2>&1
echo.
echo === Restart complete ===
echo.
type restart_output.log
echo.
echo Press any key to close...
pause >nul
