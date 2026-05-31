@echo off
set BASE=C:\Users\wsx\Desktop\claude-bridge\cluster
echo Syncing V2 worker scripts...
copy /Y "%BASE%\file_bridge\worker.ps1" "%BASE%\registry_bridge\worker.ps1" >nul
copy /Y "%BASE%\file_bridge\worker.ps1" "%BASE%\process_bridge\worker.ps1" >nul
copy /Y "%BASE%\file_bridge\worker.ps1" "%BASE%\network_bridge\worker.ps1" >nul
copy /Y "%BASE%\file_bridge\worker.ps1" "%BASE%\system_bridge\worker.ps1" >nul
:: wsl_bridge has custom WSL handler, skipped
echo Standard workers synced (wsl_bridge kept separate)
