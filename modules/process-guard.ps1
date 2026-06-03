#Requires -Version 5.0
<#
process-guard.ps1 — meta-commands + housekeeping (V18)
  Meta-commands:  __BRIDGE_RESTART__, __BRIDGE_STOP__, __BRIDGE_STATUS__
  Housekeeping:   hostLoopMode cleanup every ~60s
  Exports:        Test-MetaCommand, Run-Housekeeping
#>

. "$PSScriptRoot\bridge-core.ps1"

# ── Housekeeping counter ──────────────────────────────────────────────
$script:housekeepCount = 0
$script:housekeepInterval = 300  # every ~300 loops = ~60s at 200ms/loop, ~150s at 500ms/loop

# ── Test and handle meta-commands ─────────────────────────────────────
# Returns: $true if the command was a meta-command and was handled
function Test-MetaCommand {
    param(
        [string]$Command,
        [string]$CmdId
    )

    if ($Command -eq "__BRIDGE_RESTART__") {
        Log "[$CmdId] BRIDGE RESTART — exiting, watchdog should restart"
        Write-File $script:queueFile $script:idleWatcherQueue

        $res = @{
            state="done"; cmd_id=$CmdId; exit_code=0;
            stdout="Bridge restarting..."; stderr=""; error="";
            duration_ms=0; timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        }
        Write-File (Join-Path $script:resultDir "r_${CmdId}.json") ($res | ConvertTo-Json -Compress)
        Release-Lock
        exit 0
    }

    if ($Command -eq "__BRIDGE_STOP__") {
        Log "[$CmdId] BRIDGE STOP — exiting permanently"
        Write-File $script:queueFile $script:idleWatcherQueue

        $res = @{
            state="done"; cmd_id=$CmdId; exit_code=0;
            stdout="Bridge stopped"; stderr=""; error="";
            duration_ms=0; timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        }
        Write-File (Join-Path $script:resultDir "r_${CmdId}.json") ($res | ConvertTo-Json -Compress)
        Release-Lock
        exit 0
    }

    if ($Command -eq "__BRIDGE_STATUS__") {
        Log "[$CmdId] BRIDGE STATUS requested"

        $aliveCheck = @()
        $workers = Get-AliveWorkers
        foreach ($w in $workers) {
            $aliveCheck += "$($w.name): alive"
        }

        $statusInfo = @"
Bridge V18 — modular unified bridge
PID: $PID
Workers: $($workers.Count) alive ($($aliveCheck -join ', '))
Monitor: $($script:monitorMode)
Heartbeat: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')
"@
        $res = @{
            state="done"; cmd_id=$CmdId; exit_code=0;
            stdout=$statusInfo; stderr=""; error="";
            duration_ms=0; timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        }
        Write-File (Join-Path $script:resultDir "r_${CmdId}.json") ($res | ConvertTo-Json -Compress)
        Write-File $script:queueFile $script:idleWatcherQueue
        return $true
    }

    return $false
}

# ── Periodic housekeeping ─────────────────────────────────────────────
function Run-Housekeeping {
    $script:housekeepCount++
    if ($script:housekeepCount % $script:housekeepInterval -eq 0) {
        Clean-HostLoopMode
    }
}

# ── Clean hostLoopMode=true from session JSON files ───────────────────
function Clean-HostLoopMode {
    $sessionDirs = @("$env:LOCALAPPDATA\Claude-3p\local-agent-mode-sessions")
    $found = 0; $fixed = 0
    foreach ($sd in $sessionDirs) {
        if (-not (Test-Path $sd)) { continue }
        try {
            Get-ChildItem "$sd\*\*\*\local_*\outputs\*.json" -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $found++
                    try {
                        $content = [System.IO.File]::ReadAllText($_.FullName, $script:utf8)
                        if ($content -match '"hostLoopMode":\s*true') {
                            $content = $content -replace '"hostLoopMode":\s*true', '"hostLoopMode": false'
                            [System.IO.File]::WriteAllText($_.FullName, $content, $script:utf8)
                            $fixed++
                        }
                    } catch {}
                }
        } catch {}
    }
    if ($fixed -gt 0) {
        Log "[HOUSEKEEP] Fixed hostLoopMode in $fixed session files (scanned $found)"
    }

    # Clean stale progress files
    Get-ChildItem $script:resultDir -Filter "r_*_progress.json" -ErrorAction SilentlyContinue |
        Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 10 } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

Log "process-guard loaded"
