$proxyDir = "D:\zebbingo\tools\claude-desktop-config\proxy"

# Kill existing
$existing = netstat -ano | Select-String ":4000 "
if ($existing) {
    $parts = $existing -split '\s+'
    $ppid = $parts[-1]
    if ($ppid -match '^\d+$') {
        Stop-Process -Id $ppid -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep 2

# Quick check port is free before launch
$check = netstat -ano | Select-String ":4000 "
if ($check) {
    Write-Output "Port 4000 still in use - abort"
    exit 1
}

# Start proxy - NO output redirection to avoid buffer blocking
Start-Process powershell -ArgumentList "-NoProfile -Command cd '$proxyDir'; python server.py" -WindowStyle Hidden
Start-Sleep 4

$check2 = netstat -ano | Select-String ":4000 "
if ($check2) {
    Write-Output "Proxy started on port 4000"
} else {
    Write-Output "Proxy NOT started"
}
