#Requires -Version 5.0
<#
 Claude Bridge V21 — Guardian v3 (Self-Healing Watchdog)
 ──────────────────────────
 Monitors watcher heartbeat and worker pool health. Runs as a Scheduled Task
 every 60s. Detects crashes, stale heartbeats, and self-upgrade signals.
 Restarts watcher and/or workers as needed.

 Three layers:
   Layer 1 (Guardian):    This script — periodic health check via Scheduled Task
   Layer 2 (Watcher):     Self-upgrade detection in watcher.ps1 main loop
   Layer 3 (Worker):      Watcher skips dead workers; guardian respawns them

 Bootstrap deadlock fix:
   When ALL bridge components are down, the guardian Scheduled Task persists
   (runs every 60s) and will detect the missing heartbeat within 60s,
   then restart everything automatically. No manual intervention needed.
#>

$ErrorActionPreference = "Continue"

# ── Auto-detect paths ──
$script:scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path  # cluster/
$script:bridgeBase = Split-Path -Parent $scriptPath                   # D:\zebbingo\tools\claude-bridge
$script:watcherDir = Join-Path $script:bridgeBase "watcher"
$script:clusterDir = Join-Path $script:bridgeBase "cluster"
$script:modulesDir = Join-Path $script:bridgeBase "modules"
$script:poolFile = Join-Path $script:clusterDir ".worker_pool.json"
$script:logFile = Join-Path $script:watcherDir "guardian_v3.log"
$script:heartbeatFile = Join-Path $script:watcherDir ".watcher_heartbeat"
$script:restartFlag = Join-Path $script:watcherDir ".graceful_restart"
$script:lockFile = Join-Path $script:watcherDir ".watcher.lock"
$script:queueFile = Join-Path $script:watcherDir "queue.txt"
$script:agentScript = Join-Path $script:bridgeBase "bridge_agent.py"
$script:agentPort = 19850
$script:maintenanceLock = Join-Path $script:watcherDir ".maintenance.lock"

# ── Module imports (BridgeCommon) ──
Import-Module (Join-Path $script:modulesDir "BridgeCommon.psm1") -Force
$script:utf8 = [System.Text.UTF8Encoding]::new($false)

# ── Wrapper + aliases for backward compatibility ──
function Log { param([string]$m)
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | [GUARDIAN] $m"
    try {
        Write-BridgeLog -Message "[GUARDIAN] $m" -LogFile $script:logFile
        if ($script:guardianRunCount % 50 -eq 0) { Invoke-LogRotation -Path $script:logFile -MaxLines 500 }
    } catch { }
}
Set-Alias Write-Text  Write-SafeFile
Set-Alias Read-Json   Read-SafeJson
function Read-Text { param([string]$path) Read-SafeText -Path $path }

$script:heartbeatStaleSeconds = 120
$script:guardianRunCount = 0
$script:lastWorkerDeployTime = $null  # tracks when workers were last deployed (avoids false startup alerts)
$script:memCritical = $false          # V3.1: memory pressure flag for worker reduction
$script:pipeHealthCache = @{}          # V3.2: per-worker pipe health state
$script:lastWorkerRotateTime = $null   # V3.2: last rolling restart time
# log rotation handled by Invoke-LogRotation from BridgeCommon (500 lines)

# ── Maintenance lock protocol ──
function Test-MaintenanceLock {
    <#
     Checks whether a maintenance lock exists and is still valid.
     Returns $true if locked (skip all recovery), $false if clear to act.
     Locks with expired TTL are treated as stale and auto-cleared.
    #>
    $lockPath = $script:maintenanceLock
    if (-not (Test-Path $lockPath)) { return $false }
    try {
        $lock = Read-Json $lockPath
        if (-not $lock -or -not $lock.started_at) {
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        $ttl = if ($lock.ttl) { $lock.ttl } else { 1800 }
        $started = [DateTime]::ParseExact($lock.started_at, "yyyy-MM-dd HH:mm:ss", $null)
        $age = [int]((Get-Date) - $started).TotalSeconds
        if ($age -ge $ttl) {
            Log "Maintenance lock EXPIRED ($age`s >= $ttl`s) — clearing"
            Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
            return $false
        }
        Log "Maintenance lock ACTIVE (age=$age`s, ttl=$ttl`s, reason=$($lock.reason)) — skipping recovery"
        return $true
    } catch {
        Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

# ── Memory thresholds ──
$script:memWarnPercent = 10   # warn when free memory below 10%
$script:memCritPercent = 5    # critical — force worker reduction
$script:lastMemWarning = $null

function Get-MemoryPressure {
    <#
     Returns @{freeMB=N; totalMB=N; freePct=N; warning=bool; critical=bool}
    #>
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if (-not $os) { return $null }
        $freeMB  = [math]::Round($os.FreePhysicalMemory / 1024)
        $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1024)
        $freePct = [math]::Round($freeMB / $totalMB * 100, 1)
        return @{
            freeMB    = $freeMB
            totalMB   = $totalMB
            freePct   = $freePct
            warning   = ($freePct -lt $script:memWarnPercent)
            critical  = ($freePct -lt $script:memCritPercent)
        }
    } catch { return $null }
}

function Test-WorkerNamedPipe {
    param([string]$WorkerId, [string]$PipeName)
    $entry = $script:pipeHealthCache[$WorkerId]
    if (-not $entry) { $entry = @{healthy=$true; fail_count=0}; $script:pipeHealthCache[$WorkerId] = $entry }
    try {
        $testPipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $testPipe.Connect(500); $testPipe.Close(); $testPipe.Dispose()
        $entry.healthy = $true; $entry.fail_count = 0; return $true
    } catch {
        $entry.fail_count++
        if ($entry.fail_count -ge 3) { $entry.healthy = $false }
        return $false
    }
}
# ── Worker type definitions (matching worker_factory.ps1) ──
# V3.1: Reduced worker counts to mitigate memory pressure (was: generic=6, file=4, process=2, system=2)
$script:workerTypes = @(
    @{type="generic"; count=6},   # actively used by WSL/system/process commands
    @{type="file";    count=2},   # reduced from 4
    @{type="process"; count=1},   # reduced from 2
    @{type="system";  count=1},   # reduced from 2
    @{type="wsl";     count=1},
    @{type="user";    count=1}
)

# ============================================================
# State Checks
# ============================================================

function Get-WatcherStatus {
    <#
     Returns: "alive" if heartbeat fresh and process exists
              "stale"  if heartbeat expired or missing
              "dead"   if no process and no heartbeat
    #>
    $hb = Read-Text $script:heartbeatFile
    if (-not $hb) {
        # No heartbeat file at all
        $proc = Get-WatcherProcess
        if ($proc) { return "alive" }  # process running but no HB yet (startup)
        return "dead"
    }

    # Parse heartbeat timestamp
    try {
        $hbTime = [DateTime]::ParseExact($hb, "yyyy-MM-dd HH:mm:ss.fff", $null)
        $age = [int]((Get-Date) - $hbTime).TotalSeconds
    } catch {
        return "stale"  # unparseable heartbeat = stale
    }

    if ($age -gt $script:heartbeatStaleSeconds) {
        return "stale"
    }

    # Heartbeat fresh — check process actually exists
    $proc = Get-WatcherProcess
    if (-not $proc) {
        return "stale"  # HB file exists but process is gone (crashed)
    }

    return "alive"
}

function Get-WatcherProcess {
    $lock = Read-Text $script:lockFile
    if ($lock -match '^\d+$') {
        try {
            $p = Get-Process -Id [int]$lock -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'powershell') { return $p }
        } catch {}
    }
    # Fallback: search by command line
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'watcher\.ps1') {
                return (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue)
            }
        }
    } catch {}
    return $null
}

function Get-WorkerPoolStatus {
    <#
     Returns: @{total=N; alive=N; dead=N; deadWorkers=@(...)}
    #>
    $pool = Read-Json $script:poolFile
    $result = @{total=0; alive=0; dead=0; deadWorkers=@(); pool=$pool}

    if (-not $pool -or -not $pool.workers -or $pool.workers.Count -eq 0) {
        return $result
    }

    $result.total = $pool.workers.Count
    foreach ($w in $pool.workers) {
        $isAlive = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
        if ($isAlive) {
            $result.alive++
        } else {
            $result.dead++
            $result.deadWorkers += $w.id
        }
    }
    return $result
}

function Get-GracefulRestartFlag {
    $flag = Read-Text $script:restartFlag
    if (-not $flag) { return $null }
    try {
        return [DateTime]::ParseExact($flag, "yyyy-MM-dd HH:mm:ss.fff", $null)
    } catch {
        # If we can't parse it, it's still a valid restart signal
        return (Get-Date)
    }
}

# ============================================================
# Recovery Actions
# ============================================================

function Invoke-KillAllBridgeProcesses {
    Log "ACTION: Killing all bridge processes..."

    # 1. Kill by lock file
    $killed = @{}
    $lockPaths = @($script:lockFile)
    # Also check worker pool
    $pool = Read-Json $script:poolFile
    if ($pool -and $pool.workers) {
        foreach ($w in $pool.workers) {
            $lockPaths += Join-Path $script:clusterDir "$($w.id)\.lock"
        }
    }
    foreach ($lp in $lockPaths) {
        $pidStr = Read-Text $lp
        if ($pidStr -match '^\d+$') {
            try {
                Stop-Process -Id [int]$pidStr -Force -ErrorAction SilentlyContinue
                $killed[[int]$pidStr] = $true
                Log "  Killed PID=$pidStr (lock file)"
            } catch {}
        }
    }

    # 2. Kill by process name/pattern (catch orphans)
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($killed.ContainsKey($p.ProcessId)) { continue }
            $cl = $p.CommandLine
            if ($cl -match 'watcher\.ps1|worker_generic|worker_factory|worker_template|_bridge.*worker') {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                $killed[$p.ProcessId] = $true
                Log "  Killed PID=$($p.ProcessId) (by name match)"
            }
        }
    } catch {}

    Log "ACTION: Killed $($killed.Count) processes total"
    Start-Sleep -Seconds 2
}

function Invoke-CleanArtifacts {
    Log "ACTION: Cleaning stale artifacts..."

    # Watcher artifacts (lock files, NOT result files)
    foreach ($f in @(".watcher.lock", ".watcher_heartbeat", ".graceful_restart", ".maintenance.lock")) {
        $path = Join-Path $script:watcherDir $f
        if (Test-Path $path) { Remove-Item $path -Force; Log "  DEL watcher\$f" }
    }
    # Result files are PRESERVED — deleting them loses in-flight task results.
    # Only clean if they're truly orphaned (no corresponding pending cmd).

    # Reset queue only if corrupt (not valid JSON or stuck in running with no watcher)
    $idleJson = Get-IdleQueueJson
    $resetQueue = $false
    try {
        $queueContent = Read-Text $script:queueFile
        if ($queueContent) {
            $parsed = $queueContent | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $parsed) {
                $resetQueue = $true
                Log "  Queue corrupt (invalid JSON) — resetting"
            }
        }
    } catch { $resetQueue = $true }
    if ($resetQueue) {
        Write-Text -path $script:queueFile -content $idleJson
        Log "  Queue reset to idle"
    } else {
        Log "  Queue OK — preserving content"
    }

    # Worker artifacts
    $pool = Read-Json $script:poolFile
    if ($pool -and $pool.workers) {
        foreach ($w in $pool.workers) {
            $wDir = Join-Path $script:clusterDir $w.id
            foreach ($f in @(".lock", ".heartbeat")) {
                $path = Join-Path $wDir $f
                if (Test-Path $path) { Remove-Item $path -Force }
            }
            $wq = Join-Path $wDir "queue.txt"
            if (Test-Path $wq) { Write-Text -path $wq -content (Get-IdleQueueJson) }
        }
        Log "  Cleaned $($pool.workers.Count) worker directories"
    }
}

function Invoke-StartWatcher {
    Log "ACTION: Starting watcher..."

    # Clean stale locks before start
    foreach ($f in @(".watcher.lock", ".watcher_heartbeat", ".graceful_restart")) {
        $path = Join-Path $script:watcherDir $f
        if (Test-Path $path) { Remove-Item $path -Force }
    }

    $watcherScript = Join-Path $script:watcherDir "watcher.ps1"
    if (-not (Test-Path $watcherScript)) {
        Log "ERROR: watcher.ps1 not found at $watcherScript"
        return $false
    }

    try {
        # V2.2: .NET Process.Start — works in S4U/non-interactive contexts
        $wPsi = New-Object System.Diagnostics.ProcessStartInfo
        $wPsi.FileName = "powershell.exe"
        $wPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$watcherScript`""
        $wPsi.UseShellExecute = $false
        $wPsi.RedirectStandardOutput = $true
        $wPsi.RedirectStandardError = $true
        $wPsi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($wPsi)
        if (-not $proc) { throw "Process.Start returned null" }
        $null = $proc.BeginOutputReadLine()
        $null = $proc.BeginErrorReadLine()
        Log "  Launched watcher PID=$($proc.Id)"

        # Wait for heartbeat
        $started = Get-Date
        $lastHb = ""
        $stableCount = 0
        while ((Get-Date) -lt $started.AddSeconds(15)) {
            Start-Sleep -Milliseconds 500
            $hb = Read-Text $script:heartbeatFile
            if ($hb -and $hb -ne $lastHb) {
                $lastHb = $hb
                $stableCount++
                if ($stableCount -ge 4) {
                    $elapsed = [int]((Get-Date) - $started).TotalSeconds
                    Log "  Watcher heartbeat stable after ${elapsed}s: $hb"
                    return $true
                }
            }
        }
        Log "  WARNING: Watcher heartbeat not stable after 15s"
        return $false
    } catch {
        Log "  ERROR starting watcher: $_"
        return $false
    }
}

function Invoke-StartWorkers {
    Log "ACTION: Starting workers via worker_factory..."

    $factoryScript = Join-Path $script:clusterDir "worker_factory.ps1"
    if (-not (Test-Path $factoryScript)) {
        Log "ERROR: worker_factory.ps1 not found"
        return $false
    }

    # Kill stale worker processes first
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'worker_generic') {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                Log "  Killed orphaned worker PID=$($p.ProcessId)"
            }
        }
    } catch {}
    Start-Sleep -Seconds 1

    $script:lastWorkerDeployTime = Get-Date  # track for startup grace period

    try {
        # V2.2: .NET Process.Start + -DeployAll (single atomic pool write)
        $fwPsi = New-Object System.Diagnostics.ProcessStartInfo
        $fwPsi.FileName = "powershell.exe"
        $fwPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$factoryScript`" -DeployAll -BridgeBase `"$script:bridgeBase`""
        $fwPsi.UseShellExecute = $false
        $fwPsi.RedirectStandardOutput = $true
        $fwPsi.RedirectStandardError = $true
        $fwPsi.CreateNoWindow = $true
        $fwProc = [System.Diagnostics.Process]::Start($fwPsi)
        if (-not $fwProc) { throw "Process.Start returned null" }
        $null = $fwProc.BeginOutputReadLine()
        $null = $fwProc.BeginErrorReadLine()
        # Wait for factory to complete (DeployAll takes ~15s with heartbeat wait)
        Start-Sleep -Seconds 20
        Log "  Finished DeployAll workers"
    } catch {
        Log "  ERROR deploying workers: $_"
        $allOk = $false
    }

    # Verify
    Start-Sleep -Seconds 2  # extra time for all heartbeats
    $status = Get-WorkerPoolStatus
    Log "  Worker pool: $($status.alive)/$($status.total) alive"
    if ($status.dead -gt 0) {
        Log "  WARNING: $($status.dead) workers still dead: $($status.deadWorkers -join ', ')"
    }
    return $allOk
}

function Invoke-RespawnDeadWorkers {
    param([int]$MaxDeadBeforeRespawn = 2)

    $status = Get-WorkerPoolStatus
    if ($status.dead -eq 0) {
        Log "  All workers alive — no action needed"
        return $true
    }

    Log "  Found $($status.dead) dead workers: $($status.deadWorkers -join ', ')"

    # ── Startup grace period ──
    # If workers were deployed recently (<60s ago), some may still be starting up.
    # Wait for next cycle instead of immediately respawning (avoids false positives).
    if ($script:lastWorkerDeployTime) {
        $age = [int]((Get-Date) - $script:lastWorkerDeployTime).TotalSeconds
        if ($age -lt 60) {
            Log "  Startup grace period (${age}s < 60s) — deferring respawn to next cycle"
            return $true
        }
    }

    if ($status.dead -ge $MaxDeadBeforeRespawn) {
        Log "ACTION: Respawning all workers (threshold: $MaxDeadBeforeRespawn dead)..."
        # Remove stale pool file so factory starts clean
        if (Test-Path $script:poolFile) {
            Remove-Item $script:poolFile -Force -ErrorAction SilentlyContinue
        }
        $script:lastWorkerDeployTime = Get-Date
        return (Invoke-StartWorkers)
    }

    # For individual dead workers, just remove them from pool
    Log "  Below threshold — removing dead entries from pool"
    $pool = Read-Json $script:poolFile
    if ($pool -and $pool.workers) {
        $pool.workers = @($pool.workers | Where-Object { $_.id -notin $status.deadWorkers })
        $pool | ConvertTo-Json -Depth 3 | Out-File $script:poolFile -Encoding utf8 -NoNewline
        Log "  Removed $($status.dead) dead entries from pool"
    }
    return $true
}

# ============================================================
# Main Guardian Logic
# ============================================================

function Invoke-GuardianCheck {
    $script:guardianRunCount++
    Log "=== Guardian check #$($script:guardianRunCount) ==="

    # ── Step 0: Maintenance lock check ──
    # If a maintenance lock is active, skip ALL recovery actions.
    # This prevents guardian from overwriting in-progress upgrades.
    if (Test-MaintenanceLock) {
        Log "Maintenance lock active — skipping this cycle entirely"
        return
    }

    # ── Step 1: Check watcher status ──
    $watcherStatus = Get-WatcherStatus
    Log "Watcher status: $watcherStatus"

    # ── Step 1.5: Memory pressure check ──
    $mem = Get-MemoryPressure
    if ($mem) {
        if ($mem.critical) {
            Log "[MEMORY] CRITICAL — $($mem.freeMB)MB free / $($mem.totalMB)MB total ($($mem.freePct)%)"
            # Force immediate worker reduction: flag pool sync to skip non-essential workers
            $script:memCritical = $true
        } elseif ($mem.warning) {
            if (-not $script:lastMemWarning -or ((Get-Date) - $script:lastMemWarning).TotalSeconds -gt 300) {
                Log "[MEMORY] WARNING — $($mem.freeMB)MB free / $($mem.totalMB)MB total ($($mem.freePct)%)"
                $script:lastMemWarning = Get-Date
            }
            $script:memCritical = $false
        } else {
            $script:memCritical = $false
        }
    }
    $restartSignal = Get-GracefulRestartFlag
    if ($restartSignal) {
        Log "Graceful restart flag detected (at $restartSignal)"
        if ($watcherStatus -eq "alive") {
            # Watcher is still running (draining inflight) — wait and check next cycle
            Log "  Watcher still running — will wait for it to exit"
            # But don't leave stale flag forever; if watcher stuck >5min, force kill
            $flagAge = [int]((Get-Date) - $restartSignal).TotalSeconds
            if ($flagAge -gt 300) {
                Log "  Flag stale for ${flagAge}s — forcing restart"
                Invoke-CleanArtifacts
                Invoke-StartWatcher
            }
            # else: Wait for next guardian cycle
        } else {
            # Watcher has exited — start fresh
            Log "  Watcher has exited — starting fresh watcher"
            Remove-Item $script:restartFlag -Force -ErrorAction SilentlyContinue
            Invoke-CleanArtifacts
            Invoke-StartWatcher

            # Check if workers are also dead; respawn if needed
            $ws = Get-WorkerPoolStatus
            if ($ws.dead -ge $ws.total -or $ws.total -eq 0) {
                Log "  Workers also dead — respawning"
                Invoke-RespawnDeadWorkers
            }
        }
        return
    }

    # ── Step 3: Watcher stale or dead → full restart ──
    if ($watcherStatus -ne "alive") {
        Log "ACTION: Watcher $watcherStatus — initiating full restart"
        Invoke-KillAllBridgeProcesses
        Invoke-CleanArtifacts
        $watcherOk = Invoke-StartWatcher
        if ($watcherOk) {
            Invoke-StartWorkers
        } else {
            Log "ERROR: Failed to start watcher — will retry next cycle"
        }
        return
    }

    # ── Step 4: Watcher alive — check worker pool health ──
    $ws = Get-WorkerPoolStatus
    Log "Worker pool: $($ws.alive)/$($ws.total) alive"
    if ($ws.dead -gt 0) {
        Invoke-RespawnDeadWorkers
    }


    # ── Step 4.5: Worker NamedPipe health check (V3.2) ──
    $pipeCheckCount = 0; $pipeFailCount = 0
    if ($ws.pool -and $ws.pool.workers) {
        $checkList = @($ws.pool.workers | Where-Object { $_.pipe -and $_.type -ne "wsl" })
        for ($i = 0; $i -lt [Math]::Min(3, $checkList.Count); $i++) {
            $w = $checkList[$i % $checkList.Count]
            if (Test-WorkerNamedPipe -WorkerId $w.id -PipeName $w.pipe) { $pipeCheckCount++ } else {
                $pipeFailCount++; $ps = $script:pipeHealthCache[$w.id]
                if ($ps -and $ps.fail_count -ge 3 -and -not $ps.healthy) {
                    Log "  PIPE: $($w.id) unresponsive (fail count=$($ps.fail_count)) — subprocess fallback active"
                }
            }
        }
    }
    if ($pipeCheckCount -gt 0) { Log "  Pipe check: $pipeCheckCount OK, $pipeFailCount failed" }

    # ── Step 4.6: Rolling restart for workers >24h (V3.2) ──
    if ($ws.pool -and $ws.pool.workers -and $ws.total -gt 0) {
        $rotateInterval = if ($script:memCritical) { 12 } else { 24 }
        $now = Get-Date; $shouldRotate = $false
        if ($script:lastWorkerRotateTime) {
            $hoursSince = ($now - $script:lastWorkerRotateTime).TotalHours
            if ($hoursSince -ge $rotateInterval) { $shouldRotate = $true }
        } else { $script:lastWorkerRotateTime = $now }
        if ($shouldRotate) {
            $oldest = $null; $oldestStart = $now
            foreach ($w in $ws.pool.workers) {
                if ($w.started) {
                    try { $started = [DateTime]::ParseExact($w.started, "yyyy-MM-dd HH:mm:ss", $null); if ($started -lt $oldestStart) { $oldestStart = $started; $oldest = $w } } catch {}
                }
            }
            if ($oldest) {
                $ageHours = [math]::Round(($now - $oldestStart).TotalHours, 1)
                Log "ACTION: Rolling restart of $($oldest.id) (age=${ageHours}h)"
                try { Stop-Process -Id $oldest.pid -Force -ErrorAction SilentlyContinue; Log "  Killed PID=$($oldest.pid) — will be respawned" } catch { Log "  ERROR killing $($oldest.id): $_" }
                $script:lastWorkerRotateTime = $now
            }
        }
    }
    # ── Step 5: Check bridge_agent (TCP :19850) health ──
    $agentAlive = $false
    try {
        $agentCheck = Get-NetTCPConnection -LocalPort $script:agentPort -State Listen -ErrorAction SilentlyContinue
        if ($agentCheck) {
            $agentAlive = $true
            Log "BridgeAgent: alive (port $($script:agentPort) listening, pid=$($agentCheck.OwningProcess))"
        }
    } catch { }

    if (-not $agentAlive -and (Test-Path $script:agentScript)) {
        # ── Anti-flap: backoff if bridge_agent keeps dying ──
        $restartTracker = Join-Path $script:watcherDir ".agent_restart_tracker.json"
        $backoff = 1
        try {
            $tracker = Read-Json $restartTracker
            if ($tracker -and $tracker.count -gt 0) {
                $lastAttempt = if ($tracker.last_attempt) {
                    [DateTime]::ParseExact($tracker.last_attempt, "yyyy-MM-dd HH:mm:ss", $null)
                } else { (Get-Date).AddSeconds(-60) }
                $sinceLast = [int]((Get-Date) - $lastAttempt).TotalSeconds
                if ($sinceLast -lt 120) {
                    # Multiple failures within 2 min — apply backoff
                    $backoff = [Math]::Min([Math]::Pow(2, $tracker.count), 30)
                    Log "BridgeAgent: anti-flap backoff ${backoff}s (restart #$($tracker.count) in last ${sinceLast}s)"
                    Start-Sleep -Seconds $backoff
                } else {
                    # Last failure was long ago — reset counter
                    $tracker.count = 0
                }
            }
        } catch {}
        # Track this attempt
        $newCount = 1
        try {
            $tracker = Read-Json $restartTracker
            $prevCount = if ($null -ne $tracker -and $null -ne $tracker.count) { $tracker.count } else { 0 }
            $newCount = $prevCount + 1
        } catch {
            $newCount = 1
        }
        try {
            Write-Text -path $restartTracker -content (ConvertTo-Json -Compress @{
                count = $newCount; last_attempt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            })
        } catch {}

        Log "BridgeAgent: DOWN — port $($script:agentPort) not listening, restarting... (attempt #$newCount)"
        try {
            $agentLogStdout = Join-Path $script:watcherDir "bridge_agent_stdout.log"
            $agentLogStderr = Join-Path $script:watcherDir "bridge_agent_stderr.log"
            $agentProc = Start-Process -FilePath "python.exe" `
                -ArgumentList "`"$script:agentScript`"" `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $agentLogStdout `
                -RedirectStandardError $agentLogStderr
            if ($agentProc) {
                Log "  Launched bridge_agent PID=$($agentProc.Id) (stdout->$agentLogStdout)"
                Start-Sleep -Seconds 2
                $verify = Get-NetTCPConnection -LocalPort $script:agentPort -State Listen -ErrorAction SilentlyContinue
                if ($verify) {
                    Log "  BridgeAgent restarted OK (pid=$($verify.OwningProcess))"
                    # Reset counter on successful restart
                    try { Write-Text -path $restartTracker -content "{`"count`":0,`"last_attempt`":`"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`"}" } catch {}
                } else {
                    Log "  WARNING: BridgeAgent still not listening after restart"
                }
            }
        } catch {
            Log "  ERROR restarting bridge_agent: $($_.Exception.Message)"
        }
    } elseif (-not $agentAlive) {
        Log "BridgeAgent: DOWN but script not found at $script:agentScript — skipping"
    }

    # ── Step 6: Check proxy (localhost:4000) health ──
    $proxyAlive = $false
    try {
        $portCheck = Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue
        if ($portCheck) {
            $proxyAlive = $true
            Log "Proxy: alive (port 4000 listening, pid=$($portCheck.OwningProcess))"
        }
    } catch { }

    if (-not $proxyAlive) {
        Log "Proxy: DOWN — port 4000 not listening, restarting..."
        $restartScript = Join-Path $script:watcherDir "restart_proxy.ps1"
        if (Test-Path $restartScript) {
            try {
                $result = & powershell -ExecutionPolicy Bypass -File $restartScript 2>&1
                Log "  Restart result: $result"
                # Verify restart
                Start-Sleep -Seconds 2
                $verify = Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue
                if ($verify) {
                    Log "  Proxy restarted OK (pid=$($verify.OwningProcess))"
                } else {
                    Log "  WARNING: Proxy still not listening after restart"
                }
            } catch {
                Log "  ERROR restarting proxy: $($_.Exception.Message)"
            }
        } else {
            Log "  WARNING: restart_proxy.ps1 not found at $restartScript"
        }
    }

    # ── Step 7: Check user_bridge worker health ──
    $userBridgeDir = Join-Path $script:clusterDir "user_bridge"
    $userHbFile = Join-Path $userBridgeDir ".heartbeat"
    $userLockFile = Join-Path $userBridgeDir ".lock"
    $userStartedFlag = Join-Path $userBridgeDir ".user_bridge_started"
    $userRunnerScript = Join-Path $userBridgeDir "runner.ps1"

    $userBridgeDead = $false
    if (Test-Path $userHbFile) {
        try {
            $hbText = Read-Text $userHbFile
            if ($hbText) {
                $hbTime = [DateTime]::ParseExact($hbText, "yyyy-MM-dd HH:mm:ss.fff", $null)
                $hbAge = [int]((Get-Date) - $hbTime).TotalSeconds
                if ($hbAge -gt 300) {
                    Log "user_bridge: heartbeat stale (${hbAge}s > 300s) — marking dead"
                    $userBridgeDead = $true
                } else {
                    Log "user_bridge: alive (heartbeat ${hbAge}s ago)"
                }
            }
        } catch {
            Log "user_bridge: heartbeat unparseable — marking dead"
            $userBridgeDead = $true
        }
    } else {
        # No heartbeat file at all — might be initial startup
        # Check if lock file exists as a stronger signal
        if (Test-Path $userLockFile) {
            Log "user_bridge: no heartbeat but lock exists — checking PID"
            try {
                $lockPid = [int]((Read-Text $userLockFile).Trim())
                $lockProc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                if (-not $lockProc) {
                    Log "user_bridge: lock PID $lockPid dead — marking dead"
                    $userBridgeDead = $true
                } else {
                    Log "user_bridge: lock PID $lockPid alive (no heartbeat yet)"
                }
            } catch {
                Log "user_bridge: lock file corrupt — marking dead"
                $userBridgeDead = $true
            }
        } else {
            # No heartbeat, no lock — worker never started or crashed cleanly
            Log "user_bridge: no heartbeat, no lock — marking dead"
            $userBridgeDead = $true
        }
    }

    if ($userBridgeDead) {
        Log "user_bridge: RESTARTING..."
        # Kill stale lock PID if alive
        if (Test-Path $userLockFile) {
            try {
                $lockPid = [int]((Read-Text $userLockFile).Trim())
                Stop-Process -Id $lockPid -Force -ErrorAction SilentlyContinue
                Log "  Killed stale user_bridge PID=$lockPid"
            } catch {}
        }
        # Remove started flag so runner.ps1 allows launch
        if (Test-Path $userStartedFlag) {
            Remove-Item $userStartedFlag -Force -ErrorAction SilentlyContinue
            Log "  Removed .user_bridge_started flag"
        }
        # Reset queue
        $userQueue = Join-Path $userBridgeDir "queue.txt"
        if (Test-Path $userQueue) {
            Write-Text -path $userQueue -content '{"v":3,"state":"idle"}'
            Log "  Reset user_bridge queue to idle"
        }
        # Launch runner
        if (Test-Path $userRunnerScript) {
            try {
                $runPsi = New-Object System.Diagnostics.ProcessStartInfo
                $runPsi.FileName = "powershell.exe"
                $runPsi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$userRunnerScript`""
                $runPsi.UseShellExecute = $false
                $runPsi.RedirectStandardOutput = $true
                $runPsi.RedirectStandardError = $true
                $runPsi.CreateNoWindow = $true
                $runProc = [System.Diagnostics.Process]::Start($runPsi)
                if ($runProc) {
                    $runProc.WaitForExit(15000) | Out-Null
                    $runnerExitCode = $runProc.ExitCode
                    $runnerStderr = $runProc.StandardError.ReadToEnd().Trim()
                    $runProc.Dispose()
                    Log "  runner.ps1 exit=$runnerExitCode stderr=$runnerStderr"
                    Start-Sleep -Seconds 3
                    $verifyHb = Read-Text $userHbFile -ErrorAction SilentlyContinue
                    if ($verifyHb) {
                        Log "  user_bridge worker heartbeat confirmed: $verifyHb"
                    } else {
                        Log "  WARNING: user_bridge worker not started — runner exit=$runnerExitCode"
                        if ($runnerStderr) { Log "  runner stderr: $runnerStderr" }
                    }
                }
            } catch {
                Log "  ERROR launching user_bridge: $($_.Exception.Message)"
            }
        } else {
            Log "  ERROR: runner.ps1 not found at $userRunnerScript"
        }
    }

    # ── Step 8: Write guardian heartbeat for guard-dog (V3.2) ──
    $ghb = Join-Path $script:watcherDir ".guardian_heartbeat"
    try {
        [System.IO.File]::WriteAllText($ghb, (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $script:utf8)
    } catch { }

    Log "=== Guardian check #$($script:guardianRunCount) complete ==="
}

# ============================================================
# Entry point
# ============================================================

try {
    $logDir = Split-Path $script:logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    Invoke-GuardianCheck
} catch {
    $ex = $_.Exception.ToString()
    Log "FATAL: Unhandled exception: $ex"
    exit 1
}

exit 0
