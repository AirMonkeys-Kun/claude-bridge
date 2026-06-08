# fix_and_rebuild.ps1 - Phase 1: Stop bridge_agent, rebuild workers, restart
$ErrorActionPreference = 'SilentlyContinue'
$dir = "D:\zebbingo\tools\claude-bridge"

Write-Output "=== Phase 1: Kill existing bridge_agent ==="
Get-Process python -ErrorAction SilentlyContinue | Where-Object {
    $cmd = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" | Select-Object -ExpandProperty CommandLine
    $cmd -match 'bridge_agent'
} | ForEach-Object {
    Stop-Process -Id $_.Id -Force
    Write-Output ("Killed bridge_agent PID " + $_.Id)
}
Start-Sleep -Seconds 2

# Verify port 19850 is free
$listening = $false
for ($i = 0; $i -lt 5; $i++) {
    $check = netstat -ano | Select-String ':19850 ' | Select-String LISTENING
    if (-not $check) { $listening = $false; break }
    Write-Output "Waiting for port 19850 to release..."
    Start-Sleep -Seconds 1
}

Write-Output "=== Phase 2: Clean old cache files ==="
$poolFile = "$dir\cluster\.worker_pool.json"
if (Test-Path $poolFile) {
    $emptyPool = @{workers=@();version='2.2';created=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss');updated=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')}
    $emptyPool | ConvertTo-Json | Set-Content $poolFile -Encoding UTF8
    Write-Output "Pool cleared"
}

# Kill stale named pipe worker processes
Get-Process powershell -ErrorAction SilentlyContinue | Where-Object {
    $cmd = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" | Select-Object -ExpandProperty CommandLine
    $cmd -match 'worker_runner'
} | ForEach-Object {
    Stop-Process -Id $_.Id -Force
    Write-Output ("Killed stale worker PID " + $_.Id)
}

Write-Output "=== Phase 3: Rebuild worker pool ==="
$factory = "$dir\cluster\worker_factory.ps1"
if (Test-Path $factory) {
    # Create generic workers (main type for PowerShell commands)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $factory -Type generic -Count 4 -BridgeBase $dir 2>&1 | ForEach-Object { Write-Output $_ }
    Write-Output "Generic workers created"

    # Create file workers
    & powershell -NoProfile -ExecutionPolicy Bypass -File $factory -Type file -Count 2 -BridgeBase $dir 2>&1 | ForEach-Object { Write-Output $_ }
    Write-Output "File workers created"
}

Start-Sleep -Seconds 3

Write-Output "=== Phase 4: Verify pool ==="
if (Test-Path $poolFile) {
    $pool = Get-Content $poolFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output ("Total workers: " + $pool.workers.Count)
    $aliveCount = 0
    foreach ($w in $pool.workers) {
        $alive = [bool](Get-Process -Id $w.pid -ErrorAction SilentlyContinue)
        if ($alive) { $aliveCount++ }
        Write-Output ("  " + $w.id + " pid=" + $w.pid + " alive=" + $alive + " type=" + $w.type)
    }
    Write-Output ("Alive workers: " + $aliveCount)
} else {
    Write-Output "Pool file missing!"
}

Write-Output "=== Phase 5: Start bridge_agent ==="
$p = Start-Process -NoNewWindow -PassThru python "$dir\bridge_agent.py" -WorkingDirectory $dir
Start-Sleep -Seconds 3
$ba = netstat -ano | Select-String ':19850 ' | Select-String LISTENING
if ($ba) {
    Write-Output ("bridge_agent started PID=" + $p.Id + " on port 19850")
} else {
    Write-Output "WARNING: bridge_agent might not be listening yet"
}

Start-Sleep -Seconds 2

Write-Output "=== Phase 6: Health check ==="
try {
    $h = Invoke-WebRequest -Uri http://127.0.0.1:19851/health -UseBasicParsing -TimeoutSec 3
    Write-Output ("Health: " + $h.Content)
} catch {
    Write-Output ("Health FAILED: " + $_.Exception.Message)
}

Write-Output "=== Phase 7: Named pipe test ==="
try {
    $tcp = New-Object Net.Sockets.TcpClient
    $tcp.Connect('127.0.0.1', 19850)
    $s = $tcp.GetStream()
    $writer = New-Object System.IO.StreamWriter($s)
    $reader = New-Object System.IO.StreamReader($s)
    $cmd = @{cmd_id='verify_pipe';command='Write-Output named_pipe_works';type='powershell';timeout=10} | ConvertTo-Json -Compress
    $writer.WriteLine($cmd)
    $writer.Flush()
    Start-Sleep -Seconds 5
    $resp = $reader.ReadLine()
    Write-Output ("Pipe test result: " + $resp)
    $tcp.Close()
} catch {
    Write-Output ("Pipe test FAILED: " + $_.Exception.Message)
}

Write-Output "=== All done ==="
