#Requires -Version 5.0
<#
.SYNOPSIS
    Claude Bridge V22+ — Modular watcher (Phase 4 Step 1).
.DESCRIPTION
    Main loop with handlers extracted to watcher/handlers/*.ps1 and watcher/lib/*.ps1.
    No logic change — pure physical split from the original 920-line watcher.ps1.

    Dot-sourcing order:
      1. lib/logging.ps1     — Log function + Write-Text/Read-Json aliases
      2. lib/common.ps1      — State vars, FSW init (NO module imports — see NOTE)
      3. handlers/*.ps1      — 9 extracted handler functions

    NOTE: All Import-Module calls are HERE (before dot-source), NOT in
    lib/common.ps1. Import-Module -Force removes and re-adds the module,
    which breaks function bindings established by earlier dot-sourced
    files (e.g. Log → Write-BridgeLog).
#>

# ══════════════════════════════════════════════════════════════════
# Base paths (must precede dot-source — used by lib/common.ps1)
# ══════════════════════════════════════════════════════════════════
$script:baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:queueFile = Join-Path $script:baseDir "queue.txt"
$script:logFile = Join-Path $script:baseDir "watcher.log"
$script:heartbeatFile = Join-Path $script:baseDir ".watcher_heartbeat"
$script:utf8 = [System.Text.UTF8Encoding]::new($false)

# ══════════════════════════════════════════════════════════════════
# Module imports (must precede logging — Log wraps Write-BridgeLog)
# ══════════════════════════════════════════════════════════════════
$modulesDir = Join-Path (Split-Path -Parent $script:baseDir) "modules"
Import-Module (Join-Path $modulesDir "BridgeCommon.psm1") -Force
Import-Module (Join-Path $modulesDir "BridgeExecution.psm1") -Force
Import-Module (Join-Path $modulesDir "BridgeRules.psm1") -Force

# ══════════════════════════════════════════════════════════════════
# Dot-source modules (order matters — logging first, then state, then handlers)
# ══════════════════════════════════════════════════════════════════
. $PSScriptRoot\lib\logging.ps1

# watcherScriptPath uses $MyInvocation — must be set here, not in lib/common.ps1
$script:watcherScriptPath = $MyInvocation.MyCommand.Path

# Rule engine init (must come AFTER all modules imported + logging.ps1 dot-sourced,
# BEFORE handlers/*.ps1 use Log-ExecutionError etc.)
Init-RuleEngine -BridgeBase (Split-Path -Parent $script:baseDir)
Log "Rule engine loaded from BridgeRules.psm1"

. $PSScriptRoot\lib\common.ps1
. $PSScriptRoot\handlers\inflight.ps1
. $PSScriptRoot\handlers\poll-inflight.ps1
. $PSScriptRoot\handlers\dedup.ps1
. $PSScriptRoot\handlers\rules.ps1
. $PSScriptRoot\handlers\dispatch.ps1
. $PSScriptRoot\handlers\housekeeping.ps1
. $PSScriptRoot\handlers\meta-command.ps1
. $PSScriptRoot\handlers\execution.ps1
. $PSScriptRoot\handlers\self-upgrade.ps1
. $PSScriptRoot\handlers\archiver.ps1
. $PSScriptRoot\handlers\pool-sync.ps1

# ══════════════════════════════════════════════════════════════════
# Startup — cleanup, mutex guard, queue init
# ══════════════════════════════════════════════════════════════════
Get-ChildItem "$script:baseDir\*.tmp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# Clean up sentinel from previous crash (V22.1)
$gaveUpFile = Join-Path $script:baseDir ".watcher_gave_up"
if (Test-Path $gaveUpFile) {
    try {
        $gaveUpContent = [System.IO.File]::ReadAllText($gaveUpFile, $script:utf8)
        Log "Previous crash sentinel found: $gaveUpContent"
        Remove-Item $gaveUpFile -Force -ErrorAction SilentlyContinue
    } catch { }
}

# Named Mutex singleton guard (V22.1) — kernel-level, auto-released on crash
# Uses 3s timeout: if another instance holds it, that instance is alive → we exit
try {
    if (-not $script:watcherMutex.WaitOne([TimeSpan]::FromSeconds(3))) {
        Log "Another watcher instance holds mutex '$script:watcherMutexName' — exiting"
        exit 0
    }
    Log "Mutex acquired: $script:watcherMutexName (PID=$PID)"
} catch {
    # Mutex acquisition failed (e.g. running in session without Global\ prefix access)
    # Fall back to PID lock file
    Log "WARNING: Mutex acquisition failed ($($_.Exception.Message)) — falling back to PID lock"
    $lockFile = Join-Path $script:baseDir ".watcher.lock"
    if (Test-Path $lockFile) {
        try {
            $oldPid = [int]([System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim())
            $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProc -and $oldProc.ProcessName -match "powershell") {
                Log "Another watcher PID=$oldPid already running - exiting"
                exit 0
            }
        } catch { }
    }
    try {
        [System.IO.File]::WriteAllText($lockFile, [string]$PID, $script:utf8)
        Log "PID lock acquired (fallback): $PID"
    } catch {
        Log "WARNING: could not write lock file: $_"
    }
}

Log "=== Bridge V22+ (modular) STARTED ==="

$existing = Read-Json -path $script:queueFile
if (-not $existing) {
    Reset-QueueToIdle -Path $script:queueFile
    Log "Queue created (no existing file)"
} elseif ($existing.state -eq "pending") {
    Log "Pending command preserved: $($existing.cmd_id) / $($existing.command)"
} else {
    Reset-QueueToIdle -Path $script:queueFile
    Log "Queue reset from state=$($existing.state)"
}

# Restore inflight commands from disk (P1.3 — survive self-upgrade restart)
$restoredCount = Restore-InflightFromDisk
if ($restoredCount -gt 0) {
    Log "Restored $restoredCount inflight commands from disk"
}

# Reset worker health registry on startup (P2.1)
Reset-WorkerHealth

# Sync worker pool from .lock files — prevents PID staleness (V2.3)
try {
    Sync-WorkerPool
} catch {
    Log "[WARN] Worker pool sync error (non-fatal): $($_.Exception.Message)"
}

Log "Ready — V22+ modular (ScriptBlock fast-path, 50ms FSW timeout, dual-channel)"

# ══════════════════════════════════════════════════════════════════
# Crash circuit breaker (V22.1 — prevent infinite crash loop)
# ══════════════════════════════════════════════════════════════════
$script:crashCounter = 0
$script:crashBackoff = 1
$script:crashMaxExit = 20           # Exit after this many consecutive crashes
$script:lastSuccessfulIteration = Get-Date

# ══════════════════════════════════════════════════════════════════
# Main loop — event-driven with polling fallback
# ══════════════════════════════════════════════════════════════════
$script:pollCounter = 0
while ($true) {
    try {
        # 0. Crash circuit breaker — if we reached here, previous iteration was successful
        $script:crashCounter = 0; $script:crashBackoff = 1; $script:lastSuccessfulIteration = Get-Date

        # 1. Heartbeat
        Write-Heartbeat -Path $script:heartbeatFile

        # 2. Dual-channel queue reading (P3.1):
        #    Always poll first (0-latency if command already pending),
        #    then FSW wait for next command (50ms timeout).
        $queue = Read-Json -path $script:queueFile
        if (-not $queue -or $queue.state -ne "pending") {
            $script:queueWatcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 50) | Out-Null
            # Debounce: 20ms sleep to coalesce FSW duplicate events (known Windows FSW quirk)
            Start-Sleep -Milliseconds 20
            $queue = Read-Json -path $script:queueFile
        }

        # 3. Periodic housekeeping (~every 300 loops = ~60s)
        $script:housekeepCounter++
        try { Invoke-Housekeeping -Counter $script:housekeepCounter } catch { Log "[WARN] Housekeeping error: $($_.Exception.Message)" }

        # 4. Poll for completed inflight results
        try { Invoke-PollInflight } catch { Log "[WARN] PollInflight error: $($_.Exception.Message)" }

        # 4a. Self-upgrade check — moved from fallback-only to main loop
        try { Test-SelfUpgrade } catch { Log "[WARN] SelfUpgrade error: $($_.Exception.Message)" }

        # 5. Process pending command
        if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id -ne "" -and $queue.cmd_id -ne $script:lastCmdId) {
            $cid = $queue.cmd_id
            $ctype = $queue.type
            $rawCmd = $queue.command
            $origTimeout = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }
            $t0 = Get-Date

            # 5a. Dedup check
            if (Invoke-HandleDedup -CmdId $cid -RawCmd $rawCmd) { continue }

            # 5b. Rule engine
            $ruleResult = Invoke-ApplyRules -Cmd $rawCmd -Type $ctype -CmdId $cid
            $cmd = $ruleResult.cmd
            if ($ruleResult.type -ne $ctype) { $ctype = $ruleResult.type }

            # Store cmd_id AFTER all pre-processing succeeds
            $script:lastCmdId = $cid
            Log "[$cid] type=$ctype cmd=$cmd timeout=${origTimeout}s"

            # 5c. Meta-commands (restart/stop)
            if (Invoke-MetaCommand -Cmd $cmd -CmdId $cid) { continue }

            # 5d. Inline execution
            if ($ctype -eq "__INLINE__") { Invoke-InlineExecution -CmdId $cid -RawCmd $rawCmd -StartTime $t0; continue }

            # 5e. User-context execution
            if ($ctype -eq "user") { Invoke-UserContextExecution -CmdId $cid -Cmd $cmd -Timeout $origTimeout -StartTime $t0; continue }

            # 5f. Maintenance command (set/clear/check lock — in-process, no worker)
            if ($ctype -eq "maintenance") { Invoke-MaintenanceCommand -CmdId $cid -RawCmd $cmd -StartTime $t0; continue }

            # 5g. Mark running
            Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

            # 5g. Named Pipe dispatch (async)
            $pipeDispatched = $false
            $worker = Dispatch-ToWorker -cid $cid -ctype $ctype -cmd $cmd -timeout $origTimeout
            if ($worker) {
                Add-Inflight -CmdId $cid -Worker $worker -Ctype $ctype -Cmd $cmd -Timeout $origTimeout
                # Record content hash for future dedup
                Add-ContentDedup -CmdText $rawCmd -CmdId $cid
                $pipeDispatched = $true
                Reset-QueueToIdle -Path $script:queueFile
                Log "[$cid] V22 ASYNC-DISPATCH to $($worker.id) — inflight"
            }

            # 5h. In-process fallback
            if (-not $pipeDispatched) {
                Invoke-InprocessFallback -CmdId $cid -RawCmd $rawCmd -Ctype $ctype -Timeout $origTimeout
            }
        }
    } catch {
        $script:crashCounter++
        $script:crashBackoff = [Math]::Min($script:crashBackoff * 2, 60)   # 1→2→4→8...→60 max
        $backoff = [Math]::Min($script:crashBackoff, 60)
        Log "[FATAL] Crash #$script:crashCounter — backing off ${backoff}s — $($_.Exception.Message)"

        if ($script:crashCounter -ge $script:crashMaxExit) {
            Log "[FATAL] $script:crashCounter consecutive crashes — giving up. Write sentinel and exit."
            try {
                [System.IO.File]::WriteAllText(
                    (Join-Path $script:baseDir ".watcher_gave_up"),
                    "PID=$PID | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $($script:crashCounter) crashes | last=$($_.Exception.Message)",
                    $script:utf8
                )
            } catch {}
            exit 1
        }

        # FSW recovery (only on first few crashes)
        if ($script:crashCounter -le 5) {
            try {
                if (-not $script:queueWatcher) {
                    Log "[RECOVERY] Reinitializing FileSystemWatcher"
                    $script:queueWatcher = [System.IO.FileSystemWatcher]::new($script:baseDir, "queue.txt")
                    $script:queueWatcher.EnableRaisingEvents = $true
                    Log "[RECOVERY] FSW reinitialized OK"
                }
            } catch { Log "[RECOVERY] FSW reinit failed: $_" }
        }

        # Attempt to recover pending command (only on early crashes, skip if OOM)
        if ($script:crashCounter -le 3) {
            try {
                $q = Read-Json -path $script:queueFile
                if ($q -and $q.state -eq "pending" -and $q.cmd_id -ne "" -and $q.cmd_id -ne $script:lastCmdId) {
                    Log "[POLL] catch-block process $($q.cmd_id)"
                    $script:lastCmdId = $q.cmd_id
                    if ($q.type -eq "__INLINE__") {
                        Invoke-InlineExecution -CmdId $q.cmd_id -RawCmd $q.command -StartTime (Get-Date)
                    } else {
                        Reset-QueueToIdle -Path $script:queueFile
                    }
                }
            } catch { Log "[POLL] Error: $($_.Exception.Message)" }
        }

        Start-Sleep -Seconds $backoff
    }
}
