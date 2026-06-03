#Requires -Version 5.0
<#
pipe-dispatcher.ps1 — Named Pipe IPC + file fallback to workers (V18)
  Strategy:  Named Pipe first (sub-millisecond IPC), file queue fallback.
  Pipe names: Cluster_Wkr_{name} (e.g. Cluster_Wkr_file, Cluster_Wkr_process)
  Channel map: f/file, p/process, s/system, w/wsl, u/user
  Exports:   Send-ToWorker, Get-WorkerChannels, Get-AliveWorkers
#>

. "$PSScriptRoot\bridge-core.ps1"

# ── Channel → worker directory mapping ────────────────────────────────
$script:workerChannelMap = @{
    "f"    = "file"
    "file" = "file"
    "p"    = "process"
    "process" = "process"
    "s"    = "system"
    "system"  = "system"
    "w"    = "wsl"
    "wsl"  = "wsl"
    "u"    = "user"
    "user" = "user"
}

$script:workerDirs = @("file_bridge", "process_bridge", "system_bridge", "wsl_bridge", "user_bridge")

# ── Pipe route: send command to a worker via Named Pipe ───────────────
# Returns: result object, or $null if pipe failed
function Send-ViaPipe {
    param(
        [string]$WorkerName,    # e.g. "file", "process", "system", "wsl", "user"
        [string]$CmdJson         # JSON command string
    )

    $pipeName = "Cluster_Wkr_$WorkerName"
    $pipe = $null

    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
            ".", $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut
        )
        $pipe.Connect(200)  # 200ms timeout

        $writer = New-Object System.IO.StreamWriter($pipe)
        $reader = New-Object System.IO.StreamReader($pipe)
        $writer.AutoFlush = $true

        $writer.WriteLine($CmdJson)
        $resultJson = $reader.ReadLine()
        $pipe.Close()

        if ([string]::IsNullOrWhiteSpace($resultJson)) { return $null }
        return ($resultJson | ConvertFrom-Json)
    } catch {
        Log "[DISPATCH] Pipe $pipeName failed: $($_.Exception.Message)"
        try { if ($pipe) { $pipe.Close() } } catch {}
        return $null
    }
}

# ── File fallback: write to worker's queue.txt ────────────────────────
function Send-ViaFile {
    param(
        [string]$WorkerDir,     # full directory name, e.g. "file_bridge"
        [string]$CmdJson         # JSON command string
    )

    $workerQueue = Join-Path $script:clusterDir "$WorkerDir\queue.txt"
    try {
        Write-File $workerQueue $CmdJson
        Log "[DISPATCH] File fallback: $WorkerDir"
        return $true
    } catch {
        Log "[DISPATCH] File fallback FAILED for $WorkerDir : $_"
        return $false
    }
}

# ── Wait for file-based result ────────────────────────────────────────
function Wait-FileResult {
    param(
        [string]$WorkerDir,
        [string]$CmdId,
        [int]$TimeoutMs = 10000
    )

    $resultPath = Join-Path $script:clusterDir "$WorkerDir\r_${CmdId}.json"
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
        $rr = Read-JsonFile $resultPath
        if ($rr -and ($rr.state -eq "done" -or $rr.state -eq "error")) {
            return $rr
        }
    }
    return $null
}

# ── Main dispatch: Pipe → File fallback → Wait for result ─────────────
function Send-ToWorker {
    param(
        [string]$Channel,       # f, file, p, process, s, system, w, wsl, u, user
        [string]$Command,       # raw command text
        [string]$CmdId,         # unique command ID
        [string]$Type = "p",    # p=powershell, c=cmd, i=inline, w=wsl
        [int]$TimeoutSec = 30
    )

    $workerName = $script:workerChannelMap[$Channel.ToLower()]
    $workerDir  = "${workerName}_bridge"

    if (-not $workerName) {
        return @{ state="error"; id=$CmdId; err="Unknown channel: $Channel" }
    }

    $cmdObj = @{
        id      = $CmdId
        ch      = $workerName
        c       = $Command
        t       = $Type
        to      = $TimeoutSec
        ts      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    }
    $cmdJson = ($cmdObj | ConvertTo-Json -Compress)

    # Try Named Pipe first
    $pipeResult = Send-ViaPipe -WorkerName $workerName -CmdJson $cmdJson
    if ($pipeResult) {
        Log "[$CmdId] Pipe OK: $workerName e=$($pipeResult.e) o=$($pipeResult.o.Length)chars"
        return $pipeResult
    }

    # File fallback
    Log "[$CmdId] Pipe failed for $workerName — using file fallback"
    $fileOk = Send-ViaFile -WorkerDir $workerDir -CmdJson $cmdJson
    if (-not $fileOk) {
        return @{ state="error"; id=$CmdId; err="File fallback write failed" }
    }

    # Wait for result
    $fileResult = Wait-FileResult -WorkerDir $workerDir -CmdId $CmdId -TimeoutMs ($TimeoutSec * 1000 + 5000)
    if ($fileResult) {
        Log "[$CmdId] File OK: $workerName e=$($fileResult.e) o=$($fileResult.o.Length)chars"
        return $fileResult
    }

    return @{ state="error"; id=$CmdId; err="TIMEOUT waiting for worker result" }
}

# ── Check which workers are alive ─────────────────────────────────────
function Get-AliveWorkers {
    $alive = @()
    foreach ($wdir in $script:workerDirs) {
        $hb = Read-JsonFile (Join-Path $script:clusterDir "$wdir\.heartbeat")
        $lock = Read-JsonFile (Join-Path $script:clusterDir "$wdir\.lock")
        if ($hb) {
            $alive += @{ dir=$wdir; name=($wdir -replace '_bridge',''); heartbeat=$hb; pid=$lock }
        }
    }
    return $alive
}

# ── Get channel list ──────────────────────────────────────────────────
function Get-WorkerChannels {
    return $script:workerChannelMap.Keys | Where-Object { $_.Length -le 4 } | Sort-Object -Unique
}

Log "pipe-dispatcher loaded: $($script:workerDirs.Count) worker dirs"
