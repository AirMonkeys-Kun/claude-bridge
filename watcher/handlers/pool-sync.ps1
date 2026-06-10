# ══════════════════════════════════════════════════════════════════
# Pool Sync — V2.3: Auto-sync .worker_pool.json from worker .lock files
# ══════════════════════════════════════════════════════════════════
# Prevents PID staleness when workers restart without going through
# worker_factory.ps1 (e.g. after system reboot, guardian recovery).
#
# Called at watcher startup + periodic housekeeping.
# Only writes to pool file if PIDs actually changed (avoid 9P cache churn).
# ══════════════════════════════════════════════════════════════════

$script:poolSyncCounter = 0

function Sync-WorkerPool {
    <#
    .SYNOPSIS
        Scan cluster/ worker directories, collect current PIDs from .lock
        files, verify via heartbeat + Get-Process, and update pool file
        atomically if any PID changed.
    #>
    $script:poolSyncCounter++

    $clusterDir = Join-Path (Split-Path -Parent $script:baseDir) "cluster"
    if (-not (Test-Path $clusterDir)) {
        Log "[POOLSYNC] Cluster dir not found at $clusterDir — skipping"
        return
    }

    $poolFile = $script:poolFile
    if (-not $poolFile -or -not (Test-Path $poolFile)) {
        Log "[POOLSYNC] Pool file not found — skipping"
        return
    }

    # ── 1. Read current pool ──
    $currentPool = Read-Json -path $poolFile
    if (-not $currentPool) {
        Log "[POOLSYNC] Cannot read pool file — skipping"
        return
    }

    # ── 2. Discover worker dirs in cluster/ ──
    $workerDirs = @(Get-ChildItem -Path $clusterDir -Directory | Where-Object {
        $_.Name -match '^(generic|file|process|system|user|wsl)_\d+$'
    })

    if ($workerDirs.Count -eq 0) {
        Log "[POOLSYNC] No worker directories found in $clusterDir"
        return
    }

    # ── 3. Build discovered workers ──
    $discovered = @()
    foreach ($dir in $workerDirs) {
        $wid = $dir.Name
        $lockFile = Join-Path $dir.FullName ".lock"
        $hbFile   = Join-Path $dir.FullName ".heartbeat"
        $qFile    = Join-Path $dir.FullName "queue.txt"

        # Read PID from .lock file
        $workerPid = $null
        if (Test-Path $lockFile) {
            try {
                $pidText = [System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim()
                $workerPid = [int]$pidText
            } catch {
                Log "[POOLSYNC] $wid — cannot read .lock: $_"
                continue
            }
        } else {
            Log "[POOLSYNC] $wid — no .lock file, skipping"
            continue
        }

        # Verify PID is alive
        $procAlive = $false
        try {
            $proc = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
            if ($proc) { $procAlive = $true }
        } catch {}

        if (-not $procAlive) {
            Log "[POOLSYNC] $wid — PID=$workerPid not alive, skipping"
            continue
        }

        # Read heartbeat for freshness
        $hb = ""
        if (Test-Path $hbFile) {
            try {
                $hb = [System.IO.File]::ReadAllText($hbFile, $script:utf8).Trim()
            } catch {}
        }

        # Derive type from worker ID prefix (generic_1 → generic)
        $type = $wid -replace '_\d+$', ''
        $pipeName = "Cluster_Wkr_$($wid -replace '_', '_')"

        # Fix pipe name — the convention is Cluster_Wkr_{type}_{n}, not Cluster_Wkr_{typedir}
        $pipeName = "Cluster_Wkr_$type`_$($wid -replace '^.*_', '')"

        # Queue path relative to cluster dir
        $relQueue = "cluster\$($dir.Name)\queue.txt"

        $discovered += @{
            id      = $wid
            type    = $type
            pid     = $workerPid
            pipe    = $pipeName
            queue   = $relQueue
            started = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
    }

    if ($discovered.Count -eq 0) {
        Log "[POOLSYNC] No alive workers discovered after scan"
        return
    }

    # ── 4. Compare with current pool — only write if PIDs changed ──
    $currentWorkers = @($currentPool.workers)
    $changed = $false

    # Check if any discovered PID differs from pool
    $discoveredMap = @{}
    foreach ($w in $discovered) { $discoveredMap[$w.id] = $w.pid }

    foreach ($w in $currentWorkers) {
        $expectedPid = $discoveredMap[$w.id]
        if ($expectedPid -and $expectedPid -ne [int]$w.pid) {
            $changed = $true
            break
        }
    }

    # Also check if pool has workers we didn't discover (stale entries to remove)
    if (-not $changed) {
        foreach ($w in $discovered) {
            $found = $false
            foreach ($cw in $currentWorkers) {
                if ($cw.id -eq $w.id) { $found = $true; break }
            }
            if (-not $found) { $changed = $true; break }
        }
    }

    # Also check if the pool has the wrong count of workers
    if (-not $changed -and $currentWorkers.Count -ne $discovered.Count) {
        $changed = $true
    }

    if (-not $changed) {
        Log "[POOLSYNC] No PID changes detected — pool is current ($($discovered.Count) workers)"
        return
    }

    # ── 5. Atomic pool write ──
    $newPool = @{
        version = $currentPool.version
        created = if ($currentPool.created) { $currentPool.created } else { (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        workers = $discovered
    }

    try {
        $json = $newPool | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($poolFile, $json, $script:utf8)

        # Reset the in-memory cache so the watcher picks up changes immediately
        $script:pool = $null
        $script:poolLastLoad = $null

        Log "[POOLSYNC] Updated pool: $($discovered.Count) workers ($($changed -join ', ') changed)"
    } catch {
        Log "[POOLSYNC] Write failed: $_"
    }
}
