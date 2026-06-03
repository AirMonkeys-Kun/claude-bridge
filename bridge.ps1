#Requires -Version 5.0
<#
 Claude Bridge V18 — Unified Modular Bridge
 ===========================================
 Architecture:  EventWaitHandle zero-sleep loop (scheduler pattern)
                + ScriptBlock in-process execution (V17 fast path)
                + Named Pipe worker dispatch (scheduler pattern)
                + Content dedup + inflight guard (watcher V13)
                + Progress flush (watcher V16)
                + Error learning (watcher V5)
                + Meta-commands (watcher V15)

 Exec path:     ScriptBlock (~10ms) → Pipe (~10ms+IPC) → File fallback (~50ms)
 Queue:         watcher/queue.txt (backward compat with all clients)
                cluster/master_queue.txt (batch parallel, secondary)

 Loads all modules from modules/ directory.
 Can run standalone or via restart_bridge.ps1.
#>

param(
    [string]$BridgeRoot = "",
    [switch]$SkipLock = $false
)

$ErrorActionPreference = "Continue"

# ── Resolve bridge root ───────────────────────────────────────────────
if ([string]::IsNullOrEmpty($BridgeRoot)) {
    $BridgeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$script:bridgeRoot = $BridgeRoot
$script:modulesDir = Join-Path $script:bridgeRoot "modules"

# ── Load modules ──────────────────────────────────────────────────────
$modules = @(
    "bridge-core.ps1",
    "queue-monitor.ps1",
    "command-executor.ps1",
    "pipe-dispatcher.ps1",
    "safety-guard.ps1",
    "result-collector.ps1",
    "error-learner.ps1",
    "process-guard.ps1"
)

foreach ($mod in $modules) {
    $modPath = Join-Path $script:modulesDir $mod
    if (Test-Path $modPath) {
        . $modPath
    } else {
        Write-Host "FATAL: Module not found: $modPath"
        exit 1
    }
}

# ── Load rule engine ──────────────────────────────────────────────────
$ruleEnginePath = Join-Path $script:clusterDir "rule_engine.ps1"
$script:ruleEngineLoaded = $false
if (Test-Path $ruleEnginePath) {
    try {
        . $ruleEnginePath
        if (Get-Command "Init-RuleEngine" -ErrorAction SilentlyContinue) {
            Init-RuleEngine -BridgeBase $script:bridgeRoot
            Log "Rule engine loaded from $ruleEnginePath"
            $script:ruleEngineLoaded = $true
        }
    } catch {
        Log "Rule engine load failed: $_ — continuing without rules"
    }
}

# ── PID lock ──────────────────────────────────────────────────────────
if (-not $SkipLock) {
    if (-not (Acquire-Lock)) {
        Write-Host "Another bridge instance is already running — exiting"
        exit 0
    }
}

# ── Initialize queue monitor ──────────────────────────────────────────
$monitorOk = Start-QueueMonitor
if (-not $monitorOk) {
    Log "FATAL: Queue monitor initialization failed"
    exit 1
}

# ── Cleanup stale artifacts ───────────────────────────────────────────
Get-ChildItem $script:resultDir -Filter "*.tmp" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
Clean-StaleResults

# ── Reset queue ───────────────────────────────────────────────────────
$existing = Read-Queue
if (-not $existing) {
    Write-File $script:queueFile $script:idleWatcherQueue
    Log "Queue created (no existing file)"
} elseif ($existing.state -eq "pending" -and $existing.cmd_id) {
    Log "Pending command preserved: $($existing.cmd_id) / $($existing.command)"
} else {
    Write-File $script:queueFile $script:idleWatcherQueue
    Log "Queue reset from state=$($existing.state)"
}

# ── Startup banner ────────────────────────────────────────────────────
Log "=== Bridge V18 UNIFIED STARTED ==="
Log "  Root:     $script:bridgeRoot"
Log "  Queue:    $script:queueFile"
Log "  Monitor:  $script:monitorMode"
Log "  Rules:    $(if ($script:ruleEngineLoaded) { 'loaded' } else { 'none' })"
Log "  Workers:  $(($script:workerDirs | ForEach-Object { $_ -replace '_bridge','' }) -join ', ')"
Log "Ready — V18 unified (ScriptBlock + Pipe + Guard + Progress)"

# ═══════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════

$lastCmdId = ""

while ($true) {
    try {
        # ── Heartbeat ──
        Write-Heartbeat

        # ── Wait for queue change (EventWaitHandle zero-sleep or FSW 50ms) ──
        Wait-QueueChange -TimeoutMs 500

        # ── Read queue ──
        $queue = Read-Queue

        # ── Housekeeping (periodic) ──
        Run-Housekeeping

        # ── Inflight guard ──
        $inflight = Test-Inflight
        if ($inflight -and $queue -and $queue.state -eq "pending" -and $queue.cmd_id -ne $inflight) {
            Log "[INFLIGHT] Rejecting $($queue.cmd_id) — $inflight still running"
            Write-File $script:queueFile @"
{"state":"blocked","cmd_id":"$inflight","command":"","type":""}
"@
            continue
        }

        # ── Pending command? ──
        if (-not $queue -or $queue.state -ne "pending" -or
            [string]::IsNullOrEmpty($queue.cmd_id) -or $queue.cmd_id -eq $lastCmdId) {
            continue
        }

        $lastCmdId = $queue.cmd_id
        $cid       = $queue.cmd_id
        $ctype     = if ($queue.type) { $queue.type } else { "powershell_text" }
        $rawCmd    = $queue.command
        $timeout   = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }

        Log "[$cid] RECEIVED: type=$ctype timeout=${timeout}s cmd=$rawCmd"

        # ── Meta-command? ──
        if (Test-MetaCommand -Command $rawCmd -CmdId $cid) {
            continue
        }

        # ── Content dedup ──
        if (Try-ReuseDedupResult -CmdText $rawCmd -CmdId $cid) {
            Write-File $script:queueFile $script:idleWatcherQueue
            continue
        }

        # ── Apply rules ──
        $cmd = $rawCmd
        if ($script:ruleEngineLoaded -and (Get-Command "Apply-Rules" -ErrorAction SilentlyContinue)) {
            $ruleResult = Apply-Rules -Cmd $rawCmd -Type $ctype
            $cmd = $ruleResult.cmd
            if ($ruleResult.type -ne $ctype) {
                $ctype = $ruleResult.type
                Log "[$cid] RULE: type changed $($queue.type) → $ctype"
            }
            if ($cmd -ne $rawCmd) {
                Log "[$cid] RULE: transformed ($($ruleResult.applied -join ','))"
            }
        }

        # ── Set inflight ──
        Set-Inflight $cid

        # ── Mark running ──
        Write-File $script:queueFile @"
{"state":"running","cmd_id":"$cid"}
"@

        # ═══════════════════════════════════════════════════════════════
        # EXECUTION
        # Strategy: ScriptBlock (fast) → Pipe (parallel) → Subprocess (safe)
        # ═══════════════════════════════════════════════════════════════

        $t0 = Get-Date
        $execResult = $null
        $wasFastPath = $false
        $wasDispatched = $false

        # Route based on type
        $normType = $ctype.ToLower()

        if ($normType -eq "user" -or $normType -eq "u") {
            # ── User context: dispatch to user_bridge worker ──
            Log "[$cid] USER dispatch via pipe/file → user_bridge"
            $execResult = Send-ToWorker -Channel "user" -Command $cmd -CmdId $cid -Type "p" -TimeoutSec $timeout
            $wasDispatched = $true
        } elseif ($normType -eq "wsl" -or $normType -eq "w") {
            # ── WSL context: dispatch to wsl_bridge worker ──
            Log "[$cid] WSL dispatch via pipe/file → wsl_bridge"
            $execResult = Send-ToWorker -Channel "wsl" -Command $cmd -CmdId $cid -Type "w" -TimeoutSec $timeout
            $wasDispatched = $true
        } elseif ($normType -eq "file" -or $normType -eq "f" -or
                  $normType -eq "process" -or $normType -eq "p" -or
                  $normType -eq "system" -or $normType -eq "s") {
            # ── Specific worker dispatch ──
            $ch = if ($normType -eq "p") { "process" } else { $normType }
            Log "[$cid] WORKER dispatch via pipe → ${ch}_bridge"
            $execResult = Send-ToWorker -Channel $ch -Command $cmd -CmdId $cid -Type "p" -TimeoutSec $timeout
            $wasDispatched = $true
        } else {
            # ── Direct execution: ScriptBlock fast path ──
            $execResult = Invoke-CommandSafe -Command $cmd -Type $ctype -TimeoutSec $timeout -CmdId $cid
            $wasFastPath = $execResult.wasFastPath
        }

        # ═══════════════════════════════════════════════════════════════
        # RESULT
        # ═══════════════════════════════════════════════════════════════

        if ($wasDispatched -and $execResult) {
            # Worker dispatch result format: {id, e, o, s, err, ts, d}
            $exitCode  = if ($execResult.e -ne $null) { $execResult.e } else { -1 }
            $stdout    = if ($execResult.o) { $execResult.o.ToString() } else { "" }
            $stderr    = if ($execResult.s) { $execResult.s.ToString() } else { "" }
            $errorMsg  = if ($execResult.err) { $execResult.err.ToString() } else { "" }
            $durationMs = if ($execResult.d -ne $null) { $execResult.d } else { [int]((Get-Date) - $t0).TotalMilliseconds }
            Write-Result -CmdId $cid -ExitCode $exitCode -Stdout $stdout -Stderr $stderr `
                -ErrorMsg $errorMsg -DurationMs $durationMs -WasFastPath $false
        } elseif (-not $wasDispatched -and $execResult) {
            # Direct execution result format: @{exitCode, stdout, stderr, error, durationMs, wasFastPath}
            Write-Result -CmdId $cid -ExitCode $execResult.exitCode -Stdout $execResult.stdout `
                -Stderr $execResult.stderr -ErrorMsg $execResult.error `
                -DurationMs $execResult.durationMs -WasFastPath $wasFastPath
        } else {
            # Fallback: no result
            $durationMs = [int]((Get-Date) - $t0).TotalMilliseconds
            Write-Result -CmdId $cid -ExitCode -1 -Stdout "" -Stderr "" `
                -ErrorMsg "No result from executor" -DurationMs $durationMs
        }

        # ── Error learning ──
        if ($ExitCode -ne 0) {
            Log-Error -CmdId $cid -Type $ctype -Command $rawCmd -ExitCode $ExitCode `
                -Stdout $stdout -Stderr $stderr -DurationMs $durationMs
        }

        # ── Cleanup progress ──
        Clean-Progress $cid

        # ── Clear inflight + add dedup ──
        Clear-Inflight
        Add-Dedup -CmdText $rawCmd -CmdId $cid

        # ── Reset queue ──
        $recheck = Read-Queue
        if ($recheck -and $recheck.state -eq "pending" -and $recheck.cmd_id -ne $cid) {
            Log "[$cid] New pending $($recheck.cmd_id) — preserving queue"
        } else {
            Write-File $script:queueFile $script:idleWatcherQueue
            Log "[$cid] Queue reset"
        }

    } catch {
        try {
            $exMsg = $_.Exception.Message
            $exLine = $_.InvocationInfo.ScriptLineNumber
            Log "[FATAL] Main loop exception at line $exLine : $exMsg"
            Log "[FATAL] $($_.Exception.StackTrace)"
        } catch {}
        Start-Sleep -Seconds 2
    }
}
