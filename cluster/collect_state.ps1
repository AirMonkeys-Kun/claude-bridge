#Requires -Version 5.0
param([string]$ClusterDir = "$PSScriptRoot", [int]$HistoryMax = 100)

$utf8 = [System.Text.UTF8Encoding]::new($false)
$stateFile = Join-Path $ClusterDir "global_state.json"
$historyFile = Join-Path $ClusterDir "state_history.json"
$debugLog  = Join-Path $ClusterDir "collect_debug.log"
$t0 = Get-Date
$workerNames = @('file_bridge','registry_bridge','process_bridge','network_bridge','system_bridge','wsl_bridge','user_bridge')

function DLog($m) {
    try { $dt=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($debugLog,"$dt | $m`r`n",$utf8) } catch {}
}

DLog "=== COLLECT START ==="

# ── Worker states — heartbeat + pid + queue ──
$ws = [ordered]@{}
foreach ($w in $workerNames) {
    $procId = $null; $alive = $false; $age = $null; $qs = "unknown"
    $hf = Join-Path $ClusterDir "$w\.heartbeat"
    $lf = Join-Path $ClusterDir "$w\.lock"
    $qf = Join-Path $ClusterDir "$w\queue.txt"
    if (Test-Path $lf) {
        try { $procId = [int]([System.IO.File]::ReadAllText($lf, $utf8).Trim()) } catch { DLog "  $w lock read fail: $_" }
    }
    if (Test-Path $hf) {
        try {
            $t = (Get-Item $hf).LastWriteTime
            $age = [math]::Round(((Get-Date) - $t).TotalSeconds, 1)
            if ($age -lt 90) { $alive = $true }
        } catch { DLog "  $w hb read fail: $_" }
    }
    if (Test-Path $qf) {
        try { $q = Get-Content $qf -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json; if ($q) { $qs = $q.state } } catch {}
    }
    $ws[$w] = @{ alive = $alive; pid = $procId; hb_age_s = $age; queue_state = $qs }
    DLog ("  ${w}: pid=$procId alive=$alive age=$age q=$qs")
}

# ── Scheduler heartbeat ──
$sched = @{ alive = $false; pid = $null; hb_age_s = $null }
$shf = Join-Path $ClusterDir ".heartbeat"  # scheduler writes to .heartbeat
if (Test-Path $shf) {
    try {
        $t = (Get-Item $shf).LastWriteTime
        $a = [math]::Round(((Get-Date) - $t).TotalSeconds, 1)
        if ($a -lt 90) { $sched.alive = $true }
        $sched.hb_age_s = $a
        DLog "  sched heartbeat: age=$a"
    } catch { DLog "  sched hb fail: $_" }
} else { DLog "  sched heartbeat FILE NOT FOUND" }

# ── System resources via Get-CimInstance (safe in subprocess) ──
$sys = @{}
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $totalMem = [math]::Round($os.TotalVisibleMemorySize / 1024, 0)
    $freeMem  = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    $sys.total_memory_mb = $totalMem
    $sys.free_memory_mb = $freeMem
    $sys.memory_usage_pct = [math]::Round(($totalMem - $freeMem) / $totalMem * 100, 1)
    DLog "  memory: total=${totalMem}MB free=${freeMem}MB usage=$($sys.memory_usage_pct)%"
} catch {
    DLog "  CIM memory FAIL: $_"
    $sys.memory_usage_pct = $null
}

try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
    $freeBytes  = [long]$disk.FreeSpace
    $totalBytes = [long]$disk.Size
    $sys.c_disk_free_gb  = [math]::Round($freeBytes / 1GB, 1)
    $sys.c_disk_total_gb = [math]::Round($totalBytes / 1GB, 1)
    $sys.c_disk_usage_pct = [math]::Round(($totalBytes - $freeBytes) / $totalBytes * 100, 1)
    DLog "  disk: total=$($sys.c_disk_total_gb)GB free=$($sys.c_disk_free_gb)GB usage=$($sys.c_disk_usage_pct)%"
} catch {
    DLog "  CIM disk FAIL: $_"
    $sys.c_disk_free_gb = $null
}

try {
    $svcRaw = cmd /c "sc query CoworkVMService" 2>&1 | Out-String
    if ($svcRaw -match 'STATE\s*:\s*\d+\s+(\w+)') {
        $sys.cowork_service = $matches[1]
    } else { $sys.cowork_service = "Unknown" }
    DLog "  service: $($sys.cowork_service)"
} catch { $sys.cowork_service = "Unknown"; DLog "  service FAIL: $_" }

try {
    $sys.bash_enabled = Test-Path "$env:LOCALAPPDATA\Claude-3p\vm_bundles\claudevm.bundle\rootfs.vhdx"
    DLog "  bash: $($sys.bash_enabled)"
} catch { $sys.bash_enabled = $false }

# ── Count alive ──
$aliveCount = 0; foreach ($kv in $ws.Values) { if ($kv.alive) { $aliveCount++ } }
$total = $workerNames.Count

# ── Build state ──
$state = @{
    v = 2
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    collection_time_ms = [int]((Get-Date) - $t0).TotalMilliseconds
    summary = "$aliveCount/$total workers alive"
    all_alive = ($aliveCount -eq $total -and $sched.alive)
    workers = $ws
    scheduler = $sched
    system = $sys
}

# ── Write state file ──
$json = $state | ConvertTo-Json -Depth 4 -Compress
[System.IO.File]::WriteAllText($stateFile, $json, $utf8)
DLog "  state written: $aliveCount/$total alive, sched=$($sched.alive)"

# ── Append to history (rolling) — ArrayList ──
$historyEntry = @{
    timestamp = $state.timestamp; summary = $state.summary; all_alive = $state.all_alive
    alive_count = $aliveCount; total_workers = $total; collection_time_ms = $state.collection_time_ms
    c_disk_free_gb = $sys.c_disk_free_gb; memory_usage_pct = $sys.memory_usage_pct
    cowork_service = $sys.cowork_service; bash_enabled = $sys.bash_enabled
}
$history = New-Object System.Collections.ArrayList
if (Test-Path $historyFile) {
    try {
        $hText = [System.IO.File]::ReadAllText($historyFile, $utf8)
        $parsed = $hText | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($parsed -and $parsed.Count -gt 0) { [void]$history.AddRange($parsed) }
    } catch { DLog "  history read fail: $_" }
}
[void]$history.Add($historyEntry)
if ($history.Count -gt $HistoryMax) { $history.RemoveRange(0, $history.Count - $HistoryMax) }
[System.IO.File]::WriteAllText($historyFile, ($history | ConvertTo-Json -Compress), $utf8)
DLog "  history: $($history.Count) entries"

$elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
Write-Output "COLLECTED v=2 alive=$aliveCount/$total sched=$($sched.alive) disk=$($sys.c_disk_free_gb)GB mem=$($sys.memory_usage_pct)% svc=$($sys.cowork_service) bash=$($sys.bash_enabled) took=${elapsed}ms"
DLog "=== COLLECT DONE (${elapsed}ms) ==="
