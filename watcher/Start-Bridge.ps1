Write-Host "=== Claude Bridge Watcher Launcher ===" -ForegroundColor Cyan
$d = Split-Path -Parent $MyInvocation.MyCommand.Path

# Kill old watchers
$old = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*watcher*ps1*" }
if ($old) {
    $c = ($old | Measure-Object).Count
    foreach ($p in $old) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host "[STOPPED] $c old process(es)" -ForegroundColor Yellow
    Start-Sleep 1
}

# Start watcher directly
Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$d\watcher.ps1`""
Start-Sleep 2

# Verify
$w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*watcher*ps1*" }
if ($w) {
    Write-Host "[STARTED] Watcher PID $($w.ProcessId)" -ForegroundColor Green
    Write-Host "[MODE]    Polling 200ms — stable direct I/O" -ForegroundColor Green
}

Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
