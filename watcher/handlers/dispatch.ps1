# ══════════════════════════════════════════════════════════════════
# Worker pool + Named Pipe dispatch — extracted from watcher.ps1 V22
# ══════════════════════════════════════════════════════════════════

# ℹ️ Worker health registry (P2.1 partial — in-memory, not yet persisted)
$script:workerHealth = @{}

function Reset-WorkerHealth {
    <#.SYNOPSIS Clear worker health registry on startup / after pool reload.#>
    $script:workerHealth = @{}
}

function Test-WorkerPipeHealth {
    <#.SYNOPSIS Quick pre-flight check: ping worker pipe with adaptive timeout.
     Returns $true if pipe responds, $false otherwise.
     Updates health registry on failure.
     WSL workers get 2000ms timeout (interop latency), others 100ms.#>
    param([string]$PipeName, [string]$WorkerId, [string]$WorkerType = "")

    try {
        # Adaptive timeout: 2000ms for WSL, 100ms for others
        $timeout = if ($WorkerType -eq "wsl") { 2000 } else { 100 }

        $testPipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $testPipe.Connect($timeout)
        $testPipe.Close()
        $testPipe.Dispose()
        # Mark healthy
        if ($script:workerHealth.ContainsKey($WorkerId)) {
            $h = $script:workerHealth[$WorkerId]
            $h.failure_count = 0
            $h.status = "healthy"
            $h.last_seen_healthy = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        } else {
            $script:workerHealth[$WorkerId] = @{
                last_seen_healthy = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                failure_count = 0
                status = "healthy"
            }
        }
        return $true
    } catch {
        # Update degraded state
        if ($script:workerHealth.ContainsKey($WorkerId)) {
            $h = $script:workerHealth[$WorkerId]
            $h.failure_count++
            if ($h.failure_count -ge 10) { $h.status = "dead" }
            elseif ($h.failure_count -ge 3) { $h.status = "degraded" }
        } else {
            $script:workerHealth[$WorkerId] = @{
                last_seen_healthy = $null
                failure_count = 1
                status = "degraded"
                degraded_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            }
        }
        return $false
    }
}

function Get-WorkerPool {
    $now = Get-Date
    if (-not $script:pool -or -not $script:poolLastLoad -or (($now - $script:poolLastLoad).TotalSeconds -gt 30)) {
        $p = Read-Json -path $script:poolFile
        if ($p -and $p.workers -and $p.workers.Count -gt 0) {
            $script:pool = $p
            $script:poolLastLoad = $now
        }
    }
    return $script:pool
}

function Get-WorkerForType {
    param([string]$ctype)

    $pool = Get-WorkerPool
    if (-not $pool -or -not $pool.workers) { return $null }

    $targetType = switch ($ctype) {
        "wsl"   { "wsl" }
        "user"  { "user" }
        "file"  { "file" }
        "process" { "process" }
        "system" { "system" }
        default { "generic" }
    }

    # Phase 0: Get all workers of the target type, filtered by PID alive
    $candidates = @($pool.workers | Where-Object {
        $_.type -eq $targetType -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue)
    })

    # Phase 1: Fallback to generic if target type has no live PIDs
    if ($candidates.Count -eq 0 -and $targetType -ne "generic") {
        Log "[DISPATCH] No '$targetType' worker — falling back to generic"
        $candidates = @($pool.workers | Where-Object {
            $_.type -eq "generic" -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue)
        })
    }

    if ($candidates.Count -eq 0) { return $null }

    # Phase 2: Remove busy workers (currently have an inflight command)
    $busyWorkerIds = @($script:inflight.Values | ForEach-Object { $_.worker.id })
    $available = @($candidates | Where-Object { $_.id -notin $busyWorkerIds })
    if ($available.Count -gt 0) { $candidates = $available }

    # Phase 3: Remove dead/degraded workers from health registry
    $healthyCandidates = @($candidates | Where-Object {
        $h = $script:workerHealth[$_.id]
        -not $h -or $h.status -eq "healthy" -or $h.status -eq $null
    })
    if ($healthyCandidates.Count -gt 0) { $candidates = $healthyCandidates }

    # Phase 4: Pre-flight pipe health check on selected worker (skip if already verified this cycle)
    $preferred = $null
    $idx = [Math]::Max(0, $script:workerRR[$targetType])
    for ($attempt = 0; $attempt -lt $candidates.Count; $attempt++) {
        $w = $candidates[($idx + $attempt) % $candidates.Count]
        # Skip if recently verified (< 5s ago)
        $h = $script:workerHealth[$w.id]
        if ($h -and $h.status -eq "healthy" -and $h.last_seen_healthy) {
            $lastSeen = [DateTime]::ParseExact($h.last_seen_healthy, "yyyy-MM-dd HH:mm:ss.fff", $null)
            if (((Get-Date) - $lastSeen).TotalSeconds -lt 5) {
                $preferred = $w
                break
            }
        }
        if (Test-WorkerPipeHealth -PipeName $w.pipe -WorkerId $w.id -WorkerType $w.type) {
            $preferred = $w
            break
        }
        Log "[DISPATCH] $($w.id) pipe unresponsive — skipping"
    }

    if (-not $preferred) {
        Log "[DISPATCH] No healthy $targetType worker available — returning best effort"
        $preferred = $candidates[$idx % $candidates.Count]
    }

    # Advance round-robin pointer past the selected worker
    $script:workerRR[$targetType] = ($idx + 1) % $candidates.Count
    return $preferred
}

function Dispatch-ToWorker {
    param([string]$cid, [string]$ctype, [string]$cmd, [int]$timeout)

    # Dedup: reject if this cmd_id is already inflight (defense against FSW double-fire + inflight race)
    if ($script:inflight.ContainsKey($cid)) {
        $existing = $script:inflight[$cid]
        Log "[$cid] ALREADY INFLIGHT on $($existing.worker.id) — skipping duplicate dispatch"
        return $null
    }

    $maxRetries = 3
    $lastError = $null

    for ($retry = 0; $retry -lt $maxRetries; $retry++) {
        $worker = Get-WorkerForType -ctype $ctype
        if (-not $worker) {
            Log "[$cid] No worker available for type '$ctype' (retry $retry)"
            if ($retry -eq 0) { return $null }  # no workers at all, no point retrying
            break
        }

        try {
            $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $worker.pipe, [System.IO.Pipes.PipeDirection]::InOut)
            $pipe.Connect(300)
            $reader = New-Object System.IO.StreamReader($pipe, $script:utf8)
            $writer = New-Object System.IO.StreamWriter($pipe, $script:utf8)
            $writer.AutoFlush = $true

            $cmdJson = @{cmd_id=$cid; command=$cmd; type=$ctype; timeout=$timeout} | ConvertTo-Json -Compress
            $writer.WriteLine($cmdJson)

            $ackTask = $reader.ReadLineAsync()
            $gotAck = $ackTask.Wait(100)

            $pipe.Close()
            # Mark success in health registry
            $h = $script:workerHealth[$worker.id]
            if ($h) { $h.failure_count = 0; $h.status = "healthy"; $h.last_seen_healthy = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") }
            if ($gotAck) {
                Log "[$cid] DISPATCH to $($worker.id) — ACK received"
            } else {
                Log "[$cid] DISPATCH to $($worker.id) — sent (no ACK, assumed delivered)"
            }
            return $worker
        } catch {
            $lastError = $_.Exception.Message
            Log "[$cid] DISPATCH to $($worker.id) failed (retry $retry): $lastError"
            # Mark this worker as unresponsive in health registry so next Get-WorkerForType skips it
            if ($script:workerHealth.ContainsKey($worker.id)) {
                $h = $script:workerHealth[$worker.id]
                $h.failure_count = ($h.failure_count + 1)
                if ($h.failure_count -ge 10) { $h.status = "dead" }
                elseif ($h.failure_count -ge 3) { $h.status = "degraded" }
            } else {
                $script:workerHealth[$worker.id] = @{
                    last_seen_healthy = $null
                    failure_count = 1
                    status = "degraded"
                    degraded_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                }
            }
            # Brief pause before retry to let pipe settle
            Start-Sleep -Milliseconds 50
        }
    }

    # All retries exhausted — let caller fallback to subprocess
    Log "[$cid] DISPATCH failed after $maxRetries retries: $lastError"
    return $null
}
