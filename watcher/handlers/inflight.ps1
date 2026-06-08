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
        if (-not $sa