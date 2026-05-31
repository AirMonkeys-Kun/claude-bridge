# Simple scheduler launcher
Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File "C:\Users\wsx\Desktop\claude-bridge\cluster\scheduler.ps1" -ClusterDir "C:\Users\wsx\Desktop\claude-bridge\cluster"' -WindowStyle Hidden
Write-Host "Scheduler launched"
