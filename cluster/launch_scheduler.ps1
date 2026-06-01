# Simple scheduler launcher — auto-detects path
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptDir\scheduler.ps1`" -ClusterDir `"$scriptDir`"" -WindowStyle Hidden
Write-Host "Scheduler launched"
