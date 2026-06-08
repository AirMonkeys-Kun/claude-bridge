# ══════════════════════════════════════════════════════════════════
# Inflight tracking — V3 with disk persistence (P1.3)
# ══════════════════════════════════════════════════════════════════

$script:inflightFile = Join-Path $script:baseDir ".inflight.json"

function Save-InflightToDisk {
    <#.SYNOPSIS Persist current inflight list to disk for crash recovery.#>
    if ($script:inflight.Count -eq 0) {
        # Clean up empty file to avoid stale recovery
        if (Test-Path $script:inflightFile) {
            Remove-Item $script:inflightFile -Force -ErrorAction SilentlyContinue
        }
        return
    }
    # Serialize inflight — strip runtime objects (worker), keep reconstructable data
    $serializable = @{}
    foreach ($cid in $script:inflight.Keys) {
        $info = $script:inflight[$cid]
        $serializable[$cid] = @{
            worker_id = $info.worker.id
            worker_pipe = $info.worker.pipe
            worker_type = $info.worker.type
            ctype = $info.ctype
            cmd = $info.cmd
            start_iso = $info.start.ToString("yyyy-MM-dd HH:mm:ss.fff")
            timeout = $info.timeout
        }
    }
    try {
        $json = $serializable | ConvertTo-Json -Compress -Depth 3
        Write-Text -path $script:inflightFile -content $json
    } catch {
        Log "[INFLIGHT] Save to disk failed: $($_.Exception.Message)"
    }
}

function Add-Inflight { param([string]$CmdId, $Worker, [string]$Ctype, [string]$Cmd, [int]$Timeout)
    $script:inflight[$CmdId] = @{
        worker = $Worker
        ctype = $Ctype
        cmd = $Cmd
        start = Get-Date
        timeout = $Timeout
    }
    Save-InflightToDisk
    Log "[$CmdId] INFLIGHT added — $Ctype → $($Worker.id) (${Timeout}s timeout)"
}

function Remove-Inflight { param([string]$CmdId)
    $script:inflight.Remove($CmdId)
    Save-InflightToDisk
}

function Get-InflightCount { return $script:inflight.Count }

function Restore-InflightFromDisk {
    <#.SYNOPSIS On watcher startup, recover inflight commands from disk.
     Re-dispatches commands whose workers may still be alive.#>
    if (-not (Test-Path $script:inflightFile)) { return 0 }
    try {
        $saved = Read-Json -path $script:inflightFile
        if (-not $saved -or ($saved.GetType().Name -eq "PSCustomObject" -and @($saved.PSObject.Properties).Count -eq 0)) {
            Remove-Item $script:inflightFile -Force -ErrorAction SilentlyContinue
            return 0
        }
        $restoredCount = 0
        foreach ($prop in $saved.PSObject.Properties) {
            $cid = $prop.Name
            $info = $prop.Value

            # Check if result already exists
            $rFile = Join-Path $script:baseDir "r_${cid}.json"
            if (Test-Path $rFile) {
                Log "[INFLIGHT-RESTORE] $cid — result already exists, skipping"
                continue
            }

            # Check if still within timeout
            $startTime = [DateTime]::ParseExact($info.start_iso, "yyyy-MM-dd HH:mm:ss.fff", $null)
            $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
            $remaining = $info.timeout - $elapsed
            if ($remaining -le 0) {
                Log "[INFLIGHT-RESTORE] $cid — timed out (${elapsed}s > $($info.timeout)s), writing timeout result"
                $timeoutRes = New-CommandResult -CmdId $cid -ExitCode -1 `
                    -Stdout "[RESTORE TIMEOUT]" -Stderr "" -Error "TIMEOUT (restored after ${elapsed}s)" `
                    -DurationMs ($elapsed * 1000)
                $timeoutRes.state = "error"
                Write-CommandResult -Result $timeoutRes -Directory $script:baseDir
                continue
            }

            # Reconstruct worker object (partial — enough for dispatch + inflight tracking)
            $workerObj = @{
                id = $info.worker_id
                pipe = $info.worker_pipe
                type = $info.worker_type
            }

            # Try to re-dispatch if worker is still alive
            $workerAlive = $false
            try {
                # Check if worker PID exists (need to find current PID for this worker id)
                $pool = Get-WorkerPool
                if ($pool -and $pool.workers) {
                    $currentWorker = $pool.workers | Where-Object { $_.id -eq $info.worker_id }
                    if ($currentWorker) {
                        $wp = Get-Process -Id $currentWorker.pid -ErrorAction SilentlyContinue
                        $workerAlive = $wp -ne $null
                    }
                }
            } catch {}

            if ($workerAlive) {
                $script:inflight[$cid] = @{
                    worker = $workerObj
                    ctype = $info.ctype
                    cmd = $info.cmd
                    start = (Get-Date).AddSeconds(-$elapsed)  # preserve original elapsed time
                    timeout = $remaining
                }
                Log "[INFLIGHT-RESTORE] $cid — re-dispatched to $($info.worker_id) (${remaining}s remaining)"
                $restoredCount++
            } else {
                # Worker dead — re-route to generic worker
                Log "[INFLIGHT-RESTORE] $cid — original worker $($info.worker_id) dead, re-queuing"
                $requeueCmd = @{
                    state = "pending"
                    cmd_id = $cid
                    command = $info.cmd
                    type = "powershell"
                    timeout = $remaining
                }
                Write-Text -path $script:queueFile -content ($requeueCmd | ConvertTo-Json -Compress)
                $restoredCount++
            }
        }
        # Remove the inflight file — recovery complete
        Remove-Item $script:inflightFile -Force -ErrorAction SilentlyContinue
        if ($restoredCount -gt 0) {
            Log "[INFLIGHT-RESTORE] Restored $restoredCount inflight commands"
        }
        return $restoredCount
    } catch {
        Log "[INFLIGHT-RESTORE] Failed: $($_.Exception.Message)"
        Remove-Item $script:inflightFile -Force -ErrorAction SilentlyContinue
        return 0
    }
}

function Check-InflightResults {
    $completed = 0
    $toRemove = @()

    foreach ($cid in $script:inflight.Keys) {
        try {
            $info = $script:inflight[$cid]
            $elapsed = [int]((Get-Date) - $info.start).TotalSeconds

            if ($elapsed -gt ($info.timeout + 5)) {
                Log "[$cid] INFLIGHT TIMEOUT after ${elapsed}s (>$($info.timeout)s)"
                $toRemove += $cid
                $completed++
                continue
            }

            $rFile = Join-Path $script:baseDir "r_${cid}.json"
            if (Test-Path $rFile) {
                $content = Read-Json -path $rFile
                if ($content) {
                    Log "[$cid] INFLIGHT COMPLETE — exit=$($content.exit_code) dur=$($content.duration_ms)ms"
                    try {
                        Log-ExecutionError -CmdId $cid -Type $info.ctype -Command $info.cmd `
                            -ExitCode $content.exit_code -StdoutText $content.stdout `
                            -StderrText $content.stderr -DurationMs $content.duration_ms
                    } catch {
                        Log "[$cid] Error learning failed: $($_.Exception.Message)"
                    }
                }
                $toRemove += $cid
                $completed++
                continue
            }
        } catch {
            Log "[$cid] INFLIGHT processing error: $($_.Exception.Message) — force-removing"
            $toRemove += $cid
            $completed++
        }
    }

    foreach ($cid in $toRemove) {
        Remove-Inflight -CmdId $cid
    }

    return $completed
}
