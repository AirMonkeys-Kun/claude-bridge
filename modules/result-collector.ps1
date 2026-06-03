#Requires -Version 5.0
<#
result-collector.ps1 — result writing + progress flush (V18)
  From watcher V16: writes r_{cid}.json with exit code, stdout, stderr, duration.
  Progress flush: writes r_{cid}_progress.json every N seconds during long commands.
  Exports:        Write-Result, Write-Progress, Clean-Progress
#>

. "$PSScriptRoot\bridge-core.ps1"

# ── Write final result ────────────────────────────────────────────────
function Write-Result {
    param(
        [string]$CmdId,
        [int]$ExitCode,
        [string]$Stdout,
        [string]$Stderr,
        [string]$ErrorMsg,
        [int]$DurationMs,
        [bool]$WasFastPath = $false
    )

    # Filter CLIXML noise from stderr
    $stderrClean = if ($Stderr -match '<Objs|<CLIXML') {
        Log "[$CmdId] CLIXML stripped from stderr"
        ""
    } else { $Stderr }

    $res = @{
        state      = if ($ErrorMsg) { "error" } else { "done" }
        cmd_id     = $CmdId
        exit_code  = $ExitCode
        stdout     = if ($Stdout) { $Stdout } else { "" }
        stderr     = $stderrClean
        error      = if ($ErrorMsg) { $ErrorMsg } else { "" }
        duration_ms = $DurationMs
        timestamp  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        fast_path  = $WasFastPath
    }

    $json = ($res | ConvertTo-Json -Compress)
    Write-File (Join-Path $script:resultDir "r_${CmdId}.json") $json
    Log "[$CmdId] result written: exit=$ExitCode dur=${DurationMs}ms fast=$WasFastPath"
}

# ── Write progress during long-running commands ───────────────────────
function Write-Progress {
    param(
        [string]$CmdId,
        [int]$ElapsedSec,
        [int]$Pid,
        [bool]$HasExited = $false
    )
    $progressFile = Join-Path $script:resultDir "r_${CmdId}_progress.json"
    $data = @{
        elapsed_s  = $ElapsedSec
        running    = $true
        pid        = $Pid
        has_exited = $HasExited
        note       = "Command still running; full stdout captured on completion"
    }
    try {
        Write-File $progressFile ($data | ConvertTo-Json -Compress)
    } catch {
        # Progress is best-effort; don't let it break the main loop
    }
}

# ── Clean up progress file ────────────────────────────────────────────
function Clean-Progress { param([string]$CmdId)
    $progressFile = Join-Path $script:resultDir "r_${CmdId}_progress.json"
    if (Test-Path $progressFile) {
        Remove-Item -Force $progressFile -ErrorAction SilentlyContinue
    }
}

# ── Clean stale progress/results from previous runs ───────────────────
function Clean-StaleResults {
    Get-ChildItem $script:resultDir -Filter "r_*_progress.json" -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    Log "Stale progress files cleaned"
}

Log "result-collector loaded"
