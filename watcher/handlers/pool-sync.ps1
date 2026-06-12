# ══════════════════════════════════════════════════════════════════
# Pool Sync — V2.4: Verify .worker_pool.json PIDs by Get-Process
# ══════════════════════════════════════════════════════════════════
# V2.4 replaces V2.3's broken .lock-file discovery with direct pool
# verification.  Reads the authoritative .worker_pool.json (written by
# worker_factory.ps1), checks each PID, and prunes dead entries.
# SILENT when healthy — no log spam on a stable pool.
#
# Called at watcher startup + periodic housekeeping.
# ══════════════════════════════════════════════════════════════════

$script:poolSyncCounter = 0

function _ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Convert a PSCustomObject to a hashtable (PS 5.1 compatible).
        Read-Json returns PSCustomObject; @{} + $obj fails with
        "Only hashtables can be added to hashtables".
    #>
    param($InputObject)
    $h = @{}
    if (-not $InputObject) { return $h }
    $InputObject.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
    return $h
}

function Sync-WorkerPool {
    <#
    .SYNOPSIS
        Verify pool-file workers are alive via Get-Process.  Prune dead
        PIDs atomically.  Logs only when something changes.
    #>
    $script:poolSyncCounter++

    $poolFile = $script:poolFile
    if (-not $poolFile -or -not (Test-Path $poolFile)) { return }

    # ── 1. Read current pool ──
    $currentPool = Read-Json -path $poolFile
    if (-not $currentPool -or -not $currentPool.workers) { return }
    $workers = @($currentPool.workers)
    if ($workers.Count -eq 0) { return }

    # ── 2. Verify each worker's PID — prune dead ones ──
    $alive    = @()
    $deadLog  = @()           # log entries for changed workers
    $pidDelta = $false        # any PID actually changed?

    foreach ($w in $workers) {
        $pidAlive = $false
        try {
            $proc = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
            if ($proc) { $pidAlive = $true }
        } catch {}

        if ($pidAlive) {
            # Read current heartbeat timestamp for this worker
            $hbFile = Join-Path (Join-Path (Split-Path -Parent $script:baseDir) "cluster\$($w.id)") ".heartbeat"
            $hbTime = $null
            if (Test-Path $hbFile) {
                try { $hbTime = [System.IO.File]::ReadAllText($hbFile, $script:utf8).Trim() } catch {}
            }
            $entry = _ConvertTo-Hashtable $w
            if ($hbTime) {
                # V3.1: persist last_heartbeat on every cycle so bridge_agent and
                # guardian can read it from the pool file without checking per-worker files
                $oldHb = if ($w.last_heartbeat) { $w.last_heartbeat } else { "" }
                $entry.last_heartbeat = $hbTime
                if ($hbTime -ne $oldHb) { $pidDelta = $true }
            }
            $alive += $entry
            continue
        }

        # Worker PID is dead — try .lock file for a newer PID
        $wid = $w.id
        $lockFile = Join-Path (Join-Path (Split-Path -Parent $script:baseDir) "cluster\$wid") ".lock"
        $newPid = $null
        if (Test-Path $lockFile) {
            try {
                $pidText = [System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim()
                $newPid = [int]$pidText
                $proc = Get-Process -Id $newPid -ErrorAction SilentlyContinue
                if (-not $proc) { $newPid = $null }
            } catch { $newPid = $null }
        }

        if ($newPid) {
            $updated = _ConvertTo-Hashtable $w
    