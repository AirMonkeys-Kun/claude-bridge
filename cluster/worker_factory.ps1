#Requires -Version 5.0
<#
 worker_factory.ps1 — Spawn N generic workers (V1)
 ────────────────
 Usage: .\worker_factory.ps1 -Count 4
        .\worker_factory.ps1 -Count 2 -BridgeBase D:\zebbingo\tools\claude-bridge
        .\worker_factory.ps1 -Count 0   (kill all workers)

 Output: cluster\.worker_pool.json — active worker registry
#>

param(
    [int]$Count = 3,
    [string]$BridgeBase = ""
)

if (-not $BridgeBase) {
    $BridgeBase = Split-Path -Parent $MyInvocation.MyCommand.Path
    $BridgeBase = Split-Path -Parent $BridgeBase
}

$clusterDir = Join-Path $BridgeBase "cluster"
$workerScript = Join-Path $clusterDir "worker_generic.ps1"
$poolFile = Join-Path $clusterDir ".worker_pool.json"
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Log($m) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | [FACTORY] $m" }

# ── Kill existing pool ──
Log "=== Worker Factory ==="
Log "Killing existing workers..."
if (Test-Path $poolFile) {
    try {
        $old = Get-Content $poolFile -Raw | ConvertFrom-Json
        foreach ($w in $old.workers) {
            try { Stop-Process -Id $w.pid -Force -ErrorAction SilentlyContinue; Log "  Killed PID=$($w.pid)" } catch {}
        }
    } catch {}
    Remove-Item $poolFile -Force
}

if ($Count -le 0) {
    Log "Count=0 — kill only mode. Done."
    return
}

# ── Spawn new workers ──
Log "Spawning $Count workers..."
$workers = @()
for ($i = 1; $i -le $Count; $i++) {
    $wid = "g$i"
    $workerDir = Join-Path $clusterDir "worker_generic_$wid"
    New-Item -Path $workerDir -ItemType Directory -Force | Out-Null

    # Clear old queue
    $queueFile = Join-Path $workerDir "queue.txt"
    '{"state":"idle","cmd_id":"","command":"","type":""}' | Out-File -FilePath $queueFile -Encoding utf8 -NoNewline

    # Launch worker
    try {
        $proc = Start-Process powershell.exe -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$workerScript`"",
            "-WorkerId", $wid,
            "-BridgeBase", "`"$BridgeBase`""
        ) -PassThru -WindowStyle Hidden

        $workers += @{id=$wid; pid=$proc.Id; pipe="Cluster_Wkr_generic_$wid"; queue="cluster\worker_generic_$wid\queue.txt"; started=(Get-Date -Format "yyyy-MM-dd HH:mm:ss")}
        Log "  Worker $wid : PID=$($proc.Id)"
    } catch {
        Log "  Worker $wid : FAILED to start — $_"
    }
}

# ── Verify heartbeats ──
Log "Waiting for heartbeats..."
Start-Sleep -Seconds 3

$alive = 0
foreach ($w in $workers) {
    $hbFile = Join-Path $clusterDir "worker_generic_$($w.id)\.heartbeat"
    if (Test-Path $hbFile) {
        $hb = Get-Content $hbFile -Raw
        $alive++
        Log "  Worker $($w.id) : ALIVE — HB=$($hb.Trim())"
    } else {
        Log "  Worker $($w.id) : NO HEARTBEAT (may still be starting)"
    }
}

# ── Write pool registry ──
$pool = @{
    version = "1.0"
    count = $Count
    alive = $alive
    created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    workers = $workers
}
$pool | ConvertTo-Json -Depth 3 | Out-File -FilePath $poolFile -Encoding utf8 -NoNewline

Log "=== Pool ready: $alive/$Count workers alive ==="
Log "Pool file: $poolFile"
