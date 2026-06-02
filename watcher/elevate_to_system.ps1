# elevate_to_system.ps1 — Elevate bridge from Admin to SYSTEM
$dir = "C:\Users\wsx\Desktop\claude-bridge\watcher"
$queue = Join-Path $dir "queue.txt"
$lock = Join-Path $dir ".watcher.lock"
$log = Join-Path $dir "watchdog.log"

$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")

# Step 1: Kill any existing SYSTEM-level watcher to avoid conflicts
$existing = Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match "watcher"
}
foreach ($p in $existing) {
    try { $p.Kill() } catch {}
}
Start-Sleep 1

# Step 2: Clean up stale lock file
if (Test-Path $lock) { Remove-Item $lock -Force }

# Step 3: Delete old SYSTEM task if exists
schtasks /delete /tn BridgeSYSTEM /f 2>$null

# Step 4: Create new SYSTEM task
$wPath = "$dir\watcher.ps1"
$taskCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$wPath`""
schtasks /create /tn BridgeSYSTEM /tr "$taskCmd" /ru SYSTEM /f /sc once /st 00:01 2>$null

if ($LASTEXITCODE -ne 0) {
    "$ts | [ELEVATE] Failed to create SYSTEM task (exit=$LASTEXITCODE)" | Out-File $log -Append
    exit 1
}
"$ts | [ELEVATE] SYSTEM task created" | Out-File $log -Append

# Step 5: Run the SYSTEM task
schtasks /run /tn BridgeSYSTEM
"$ts | [ELEVATE] SYSTEM task started" | Out-File $log -Append

# Step 6: Write __BRIDGE_STOP__ to queue for current admin watcher
$stopJson = '{"state":"pending","cmd_id":"e-stop-system","command":"__BRIDGE_STOP__","type":"powershell"}'
$stopJson | Out-File $queue -Encoding utf8
"$ts | [ELEVATE] STOP sent to admin watcher" | Out-File $log -Append

# Step 7: Verify SYSTEM watcher is running
Start-Sleep 2
$sysProc = Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object {
    try { $_.CommandLine -match "watcher" } catch { $false }
}
if ($sysProc) {
    "$ts | [ELEVATE] SUCCESS - SYSTEM watcher running, PID=$($sysProc[0].Id)" | Out-File $log -Append
} else {
    "$ts | [ELEVATE] WARNING - SYSTEM watcher not found yet" | Out-File $log -Append
}
