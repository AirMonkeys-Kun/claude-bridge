@echo off
title Claude Bridge V14
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0watcher\start_v14_now.ps1"
echo.
echo === Done ===
pause >nul
