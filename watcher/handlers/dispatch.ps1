# ══════════════════════════════════════════════════════════════════
# Worker pool + Named Pipe dispatch — extracted from watcher.ps1 V22
# ══════════════════════════════════════════════════════════════════

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

    $candidates = @($pool.workers | Where-Object {
        $_.type -eq $targetType -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue)
    })

    if ($candidates.Count -eq 0 -and $targetType -ne "generic") {
        Log "[DISPATCH] No '$targetType' worker — falling back to generic"
        $candidates = @($pool.workers | Where-Object {
            $_.type -eq "generic" -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue)
        })
    }

    if ($candidates.Count -eq 0) { return $null }

    $busyWorkerIds = @($script:inflight.Values | ForEach-Object { $_.worker.id })
    $available = @($candidates | Where-Object { $_.id -notin $busyWorkerIds })
    if ($available.Count -gt 0) { $candidates = $available }

    $idx = [Math]::Max(0, $script:workerRR[$targetType])
    $script:workerRR[$targetType] = ($idx + 1) % $candidates.Count
    return $candidates[$idx % $candidates.Count]
}

function Dispatch-ToWorker {
    param([string]$cid, [string]$ctype, [string]$cmd, [int]$timeout)

    $worker = Get-WorkerForType -ctype $ctype
    if (-not $worker) {
        Log "[$cid] No worker available for type '$ctype'"
        return $null
    }

    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $worker.pipe, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(2000)
        $reader = New-Object System.IO.StreamReader($pipe, $script:utf8)
        $writer = New-Object System.IO.StreamWriter($pipe, $script:utf8)
        $writer.AutoFlush = $true

        $cmdJson = @{cmd_id=$cid; command=$cmd; type=$ctype; timeout=$timeout} | ConvertTo-Json -Compress
        $writer.WriteLine($cmdJson)

        $ackTask = $reader.ReadLineAsync()
        $gotAck = $ackTask.Wait(100)

        $pipe.Close()
        if ($gotAck) {
            Log "[$cid] DISPATCH to $($worker.id) — ACK received"
        } else {
            Log "[$cid] DISPATCH to $($worker.id) — sent (no ACK, assumed delivered)"
        }
        return $worker
    } catch {
        Log "[$cid] DISPATCH to $($worker.id) failed: $($_.Exception.Message)"
        return $null
    }
}
