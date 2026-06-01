@echo off
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scheduler.ps1" -ClusterDir "%~dp0"
echo Launched scheduler
