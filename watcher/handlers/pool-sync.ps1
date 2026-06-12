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
            $entry = @{} + $w
            if ($hbTime) { $entry.last_heartbeat = $hbTime }
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
            $updated = @{} + $w
            $updated.pid = $newPid
            $updated.started = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $alive += $updated
            $deadLog  += "$wid PID $($w.pid) → $newPid"
            $pidDelta = $true
        } else {
            $deadLog += "$wid PID $($w.pid) — dead, no replacement found"
            $pidDelta = $true
        }
    }

    # ── 3. Quiet exit if nothing changed ──
    if (-not $pidDelta) { return }

    # ── 4. Atomic pool write ──
    $newPool = @{
        version = $currentPool.version
        created = if ($currentPool.created) { $currentPool.created } else { (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        workers = $alive
    }

    try {
        $json = $newPool | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($poolFile, $json, $script:utf8)

        # Reset in-memory cache so dispatcher picks up changes immediately
        $script:pool = $null
        $script:poolLastLoad = $null

        Log "[POOLSYNC] Updated pool: $($alive.Count)/$($workers.Count) workers alive"
        foreach ($entry in $deadLog) { Log "[POOLSYNC]   $entry" }
    } catch {
        Log "[POOLSYNC] Write failed: $_"
    }
}
