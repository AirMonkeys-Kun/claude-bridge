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
    <#.SYNOPSIS Quick pre-flight check: ping worker pipe with 100ms timeout.
     Returns $true if pipe responds, $false otherwise.
     Updates health registry on failure.#>
    param([string]$PipeName, [string]$WorkerId)

    try {
        $testPipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $testPipe.Connect(100)  # 100ms timeout — fast failure
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
        $_.type -eq $targetType -and (Get-Proces