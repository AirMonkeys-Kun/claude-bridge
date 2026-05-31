@echo off
start /B powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\wsx\Desktop\claude-bridge\cluster\scheduler.ps1" -ClusterDir "C:\Users\wsx\Desktop\claude-bridge\cluster"
echo Launched scheduler
