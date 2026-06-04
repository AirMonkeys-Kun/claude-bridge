#Requires -Version 5.0
<#
 pipe_daemon.ps1 — [OBSOLETE / 已弃用] 功能已融入 watcher V19
 ──────────────────────
 V20 (2026-06-04): Named Pipe dispatch logic moved into watcher.ps1.
   The watcher now dispatches commands directly to typed workers via Named Pipes.
   This file kept as reference only — DO NOT USE.
   See: watcher/watcher.ps1 → V19: Typed worker dispatch via Named Pipe

 Original purpose: Watched .pipe_master_queue.json, dispatched to workers via Named Pipes.
 Now replaced by watcher's Dispatch-ToWorker function.
#>

param(
    [string]$BridgeBase = "",
    [int]$Timeout = 30,
    [switch]$Kill
)

if (-not $BridgeBase) {
    $BridgeBase = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$clusterDir = Join-Path $BridgeBase "cluster"
$resultDir = Join-Path $BridgeBase "watcher"
$poolFile = Join-Path $clusterDir ".worker_pool.json"
$masterQueueFile = Join-Path $clusterDir ".pipe_master_queue.json"
$batchResultFile = Join-Path $clusterDir ".pipe_batch_result.json"
$daemonLogFile = Join-Path $clusterDir "pipe_daemon.log"
$daemonLockFile = Join-Path $clusterDir ".pipe_daemon.lock"
$daemonHbFile = Join-Path $clusterDir ".pipe_daemon.heartbeat"
$utf8 = [System.Text.UTF8Encoding]::new($false)

# Ensure result directory exists
if (-not (Test-Path $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }

function Log($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    $line = "$t | [DAEMON] $m"
    Write-Host $line
    try { [System.IO.File]::AppendAllText($daemonLogFile, "$line`r`n", $utf8) } catch {}
}

# ── Kill mode ──
if ($Kill) {
    if (Test-Path $daemonLockFile) {
        try {
            $oldPid = [int]([System.IO.File]::ReadAllText($daemonLockFile, $utf8).Trim())
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Log "Killed daemon PID=$oldPid"
        } catch { Log "Could not read lock file" }
        Remove-Item $daemonLockFile -Force -ErrorAction SilentlyContinue
    } else {
        Log "No daemon lock file found"
    }
    exit 0
}

# ── PID lock (singleton) ──
if (Test-Path $daemonLockFile) {
    try {
        $oldPid = [int]([System.IO.File]::ReadAllText($daemonLockFile, $utf8).Trim())
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc) {
            Log "Daemon already running PID=$oldPid — exiting"
            exit 0
        }
    } catch {}
}
[System.IO.File]::WriteAllText($daemonLockFile, [string]$PID, $utf8)

# ── Load worker pool ──
if (-not (Test-Path $poolFile)) {
    Log "FATAL: No worker pool — run worker_factory.ps1 first"
    exit 1
}

$pool = Get-Content $poolFile -Raw | ConvertFrom-Json
# Exclude g2 — permanently broken Named Pipe connect (times out ~5s per attempt)
$workers = $pool.workers | Where-Object { $_.id -ne "g2" }
$workerCount = $workers.Count
Log "=== Pipe Daemon STARTED (pid=$PID) ==="
Log "Pool: $workerCount workers loaded"

# ── FSW: watch cluster dir for master queue ──
$fsw = New-Object System.IO.FileSystemWatcher
$fsw.Path = $clusterDir
$fsw.Filter = ".pipe_master_queue.json"
$fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor [System.IO.NotifyFilters]::LastWrite
$fsw.IncludeSubdirectories = $false
Log "FSW watching: $clusterDir\.pipe_master_queue.json"

# ── Clean up stale master queue ──
if (Test-Path $masterQueueFile) {
    Log "Found stale master queue — processing"
}

# ── Main daemon loop ──
$batchCount = 0

while ($true) {
    # Heartbeat
    try { [System.IO.File]::WriteAllText($daemonHbFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $utf8) } catch {}

    # Wait for master queue file to appear/changed
    # 500ms timeout for heartbeat updates
    try {
        $change = $fsw.WaitForChanged(
            [System.IO.WatcherChangeTypes]::Created -bor [System.IO.WatcherChangeTypes]::Changed,
            500
        )
    } catch {
        Start-Sleep -Milliseconds 500
        continue
    }

    # Check if file exists and has content
    if (-not (Test-Path $masterQueueFile)) { continue }

    # Small delay to ensure file write is complete
    Start-Sleep -Milliseconds 30

    # Read batch
    try {
        $batchJson = [System.IO.File]::ReadAllText($masterQueueFile, $utf8)
        if ([string]::IsNullOrWhiteSpace($batchJson)) { continue }
        $batch = $batchJson | ConvertFrom-Json
        $commands = $batch.commands
        if (-not $commands -or $commands.Count -eq 0) { continue }
    } catch {
        # File may be partially written — skip and wait for next event
        continue
    }

    # Delete master queue immediately (mark as consumed)
    Remove-Item $masterQueueFile -Force -ErrorAction SilentlyContinue

    $batchCount++
    $total = $commands.Count
    $results = @{}
    $tBatchStart = Get-Date

    Log "Batch #$batchCount : $total commands — dispatching"

    # ══════════════════════════════════════════
    # PARALLEL DISPATCH (same as pipe_dispatcher V2)
    # ══════════════════════════════════════════

    $nextCmd = 0
    $waveNum = 0

    while ($nextCmd -lt $total) {
        $waveNum++
        $waveStart = Get-Date

        $runspaces = @()
        for ($w = 0; $w -lt $workerCount -and $nextCmd -lt $total; $w++) {
            $cmd = $commands[$nextCmd]
            $worker = $workers[$w]
            $cid = $cmd.cmd_id
            $pipeName = $worker.pipe
            $pipeJson = $cmd | ConvertTo-Json -Compress
            $nextCmd++

            $ps = [PowerShell]::Create()
            $null = $ps.AddScript({
                param($pn, $cmdJson, $to, $u8enc)
                try {
                    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
                        ".", $pn,
                        [System.IO.Pipes.PipeDirection]::InOut
                    )
                    $pipe.Connect(5000)
                    $reader = New-Object System.IO.StreamReader($pipe, $u8enc)
                    $writer = New-Object System.IO.StreamWriter($pipe, $u8enc)
                    $writer.AutoFlush = $true
                    $writer.WriteLine($cmdJson)

                    $readTask = $reader.ReadLineAsync()
                    if ($readTask.Wait(($to + 5) * 1000)) {
                        $resultJson = $readTask.Result
                        $pipe.Close()
                        return $resultJson
                    } else {
                        $pipe.Close()
                        return '{"status":"error","error":"PIPE READ TIMEOUT"}'
                    }
                } catch {
                    return "{`"status`":`"error`",`"error`":`"$($_.Exception.Message -replace '\"','\\\"')`"}"
                }
            }).AddArgument($pipeName).AddArgument($pipeJson).AddArgument($Timeout).AddArgument($utf8)

            $runspaces += @{ ps = $ps; handle = $ps.BeginInvoke(); cid = $cid; worker = $worker.id }
        }

        # Collect wave results
        foreach ($rs in $runspaces) {
            $cid = $rs.cid
            try {
                if ($rs.handle.AsyncWaitHandle.WaitOne(($Timeout + 10) * 1000)) {
                    $resultJson = $rs.ps.EndInvoke($rs.handle)
                    try {
                        $result = $resultJson | ConvertFrom-Json
                        $results[$cid] = $result
                    } catch {
                        $results[$cid] = @{status="error";cmd_id=$cid;error="JSON parse failed";duration_ms=0;fast_path=$false}
                    }
                } else {
                    $rs.ps.Stop()
                    $results[$cid] = @{status="error";cmd_id=$cid;error="RUNSPACE TIMEOUT";duration_ms=0;fast_path=$false}
                }
            } catch {
                $results[$cid] = @{status="error";cmd_id=$cid;error="Runspace failed: $_";duration_ms=0;fast_path=$false}
            }
            $rs.ps.Dispose()
        }

        $waveElapsed = [int]((Get-Date) - $waveStart).TotalMilliseconds
        Log "  Wave $waveNum : $($runspaces.Count) cmds, ${waveElapsed}ms"
    }

    $tBatchElapsed = [int]((Get-Date) - $tBatchStart).TotalMilliseconds

    # Write results
    $batchResult = @{
        total = $total
        completed = $results.Count
        batch_duration_ms = $tBatchElapsed
        waves = $waveNum
        batch_num = $batchCount
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        results = $results
    }

    [System.IO.File]::WriteAllText(
        $batchResultFile,
        ($batchResult | ConvertTo-Json -Depth 4),
        $utf8
    )

    # Write individual result files (unique filenames — bypass 9P FUSE cache)
    foreach ($rCid in $results.Keys) {
        $rObj = $results[$rCid]
        if (-not $rObj.cmd_id) { $rObj | Add-Member -NotePropertyName "cmd_id" -NotePropertyValue $rCid -Force }
        if (-not $rObj.timestamp) { $rObj | Add-Member -NotePropertyName "timestamp" -NotePropertyValue ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")) -Force }
        if (-not $rObj.duration_ms) { $rObj | Add-Member -NotePropertyName "duration_ms" -NotePropertyValue 0 -Force }
        $rFile = Join-Path $resultDir "r_$rCid.json"
        try {
            [System.IO.File]::WriteAllText($rFile, ($rObj | ConvertTo-Json -Compress), $utf8)
        } catch {
            Log "  Failed to write individual result for $rCid : $_"
        }
    }

    $pipeOk = ($results.Values | Where-Object { $_.status -eq "done" }).Count
    $durs = @($results.Values | Where-Object { $_.duration_ms -gt 0 } | ForEach-Object { $_.duration_ms })
    $avgDur = if ($durs.Count -gt 0) { [int](($durs | Measure-Object -Average).Average) } else { 0 }
    Log "Batch #$batchCount DONE: $pipeOk/$total OK, ${tBatchElapsed}ms total, avg ${avgDur}ms/cmd"

    # Brief pause before watching for next batch
    Start-Sleep -Milliseconds 50
}
