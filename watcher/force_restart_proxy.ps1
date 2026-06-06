# Force restart proxy - handles all edge cases
$proxyDir = "D:\zebbingo\tools\claude-desktop-config\proxy"

# Find and kill ALL python processes running server.py
$procs = Get-Process python -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -match 'server\.py' } catch { $false }
}
foreach ($p in $procs) {
    Write-Output "Killing PID $($p.Id) ($($p.ProcessName))"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}

# Also try by port
$conns = Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue
foreach ($c in $conns) {
    Write-Output "Killing port-4000 PID $($c.OwningProcess)"
    Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
}

Start-Sleep 3

# Verify port is free
$check = Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue
if ($check) {
    Write-Output "ERROR: Port 4000 still in use"
    exit 1
}

# Start proxy
Start-Process powershell -ArgumentList "-NoProfile -Command cd '$proxyDir'; python server.py" -WindowStyle Hidden
Start-Sleep 5

# Verify it started
$check2 = Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue
if ($check2) {
    Write-Output "OK: Proxy restarted on port 4000"
} else {
    Write-Output "ERROR: Proxy failed to start"
    exit 1
}
