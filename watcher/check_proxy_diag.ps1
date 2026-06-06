# Diagnostic - Proxy status
Write-Output "=== PORT 4000 CHECK ==="
$c = Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue
if ($c) {
    Write-Output "PORT 4000: LISTENING pid=$($c.OwningProcess) state=$($c.State)"
    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($p) {
        Write-Output "PROCESS: $($p.ProcessName) id=$($p.Id) cpu=$($p.CPU) mem=$([math]::Round($p.WorkingSet/1MB,1))MB"
        try { Write-Output ("CMDLINE: " + $p.CommandLine.Substring(0, [Math]::Min(200, $p.CommandLine.Length))) } catch {}
    }
} else {
    Write-Output "PORT 4000: NOT LISTENING"
}

Write-Output ""
Write-Output "=== PYTHON PROCESSES ==="
$pps = Get-Process python -ErrorAction SilentlyContinue
foreach ($pp in $pps) {
    Write-Output ("python pid=$($pp.Id) cpu=$($pp.CPU) mem=$([math]::Round($pp.WorkingSet/1MB,1))MB")
}

Write-Output ""
Write-Output "=== PROXY DIR ==="
if (Test-Path "D:\zebbingo\tools\claude-desktop-config\proxy") {
    cd "D:\zebbingo\tools\claude-desktop-config\proxy"
    Write-Output "server.py exists: $(Test-Path server.py)"
    Write-Output "files:"
    Get-ChildItem *.py -Name
} else {
    Write-Output "PROXY DIR NOT FOUND"
}

Write-Output ""
Write-Output "=== PROXY LOG TAIL ==="
$logPath = "D:\zebbingo\tools\claude-desktop-config\proxy\proxy_debug.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 20
} else {
    Write-Output "No proxy_debug.log found"
}
