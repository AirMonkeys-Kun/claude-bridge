# rebuild_all.ps1 — Rebuild worker pool and verify bridge_agent
$ErrorActionPreference = 'SilentlyContinue'
$dir = "D:\zebbingo\tools\claude-bridge"

Write-Output "=== Step 1: Check bridge_agent ==="
$ba = netstat -ano | Select-String ':19850 ' | Select-String LISTENING
if (-not $ba) {
    Write-Output "bridge_agent DOWN — starting..."
    $p = Start-Process -NoNewWindow -PassThru python "$dir\bridge_agent.py" -WorkingDirectory $dir
    Start-Sleep -Seconds 3
    $ba = netstat -ano | Select-String ':19850 ' | Select-String LISTENING
    if ($ba) { Write-Output "Started OK PID=$($p.Id)" } else { Write-Output "FAILED to start" }
} else {
    Write-Output ("bridge_agent OK (" + $ba.Count + " listeners)")
}

Write-Output "=== Step 2: Rebuild worker pool ==="
$poolFile = "$dir\cluster\.worker_pool.json"
$rebuildScript = "$dir\cluster\rebuild_pool.ps1"
if (Test-Path $rebuildScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $rebuildScript 2>&1 | Out-String
    Write-Output "Rebuild script executed"
}
Start-Sleep -Seconds 2

# Try worker factory instead
$factory = "$dir\cluster\worker_factory.ps1"
if (Test-Path $factory) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $factory -Type generic -Count 4 -BridgeBase $dir 2>&1 | Out-String
    Write-Output "Worker factory executed"
}

Start-Sleep -Seconds 3
Write-Output "=== Step 3: Verify pool ==="
if (Test-Path $poolFile) {
    $pool = Get-Content $poolFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output ("Workers: " + $pool.workers.Count)
    foreach ($w in $pool.workers) {
        $alive = [bool](Get-Process -Id $w.pid -ErrorAction SilentlyContinue)
        Write-Output ("  " + $w.id + " pid=" + $w.pid + " alive=" + $alive + " type=" + $w.type + " pipe=" + $w.pipe)
    }
} else {
    Write-Output "Pool file not found!"
}

Write-Output "=== Step 4: Health check ==="
try {
    $h = Invoke-WebRequest -Uri http://127.0.0.1:19851/health -UseBasicParsing -TimeoutSec 3
    $h.Content
} catch {
    Write-Output ("Health FAILED: " + $_.Exception.Message)
}

Write-Output "=== Step 5: Named pipe test ==="
# Send a simple command via the bridge_agent TCP protocol
# This should now use named pipe since pool is populated
try {
    $tcp = New-Object Net.Sockets.TcpClient
    $tcp.Connect('127.0.0.1', 19850)
    $s = $tcp.GetStream()
    $writer = New-Object System.IO.StreamWriter($s)
    $reader = New-Object System.IO.StreamReader($s)
    $cmd = @{cmd_id='test_wkr';command='Write-Output hello_from_worker';type='powershell';timeout=10} | ConvertTo-Json -Compress
    $writer.WriteLine($cmd)
    $writer.Flush()
    Start-Sleep -Seconds 5
    $resp = $reader.ReadLine()
    Write-Output ("TCP test: " + $resp)
    $tcp.Close()
} catch {
    Write-Output ("TCP test FAILED: " + $_.Exception.Message)
}

Write-Output "=== Done ==="
