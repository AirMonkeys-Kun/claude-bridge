# ══════════════════════════════════════════════════════════════════
# Meta-command handler (restart/stop) — extracted from watcher.ps1 V22
# ══════════════════════════════════════════════════════════════════

function Invoke-MetaCommand {
    <#.SYNOPSIS Handle __BRIDGE_RESTART__ and __BRIDGE_STOP__. Returns $true if handled.#>
    param([string]$Cmd, [string]$CmdId)
    if ($Cmd -eq "__BRIDGE_RESTART__") {
        Log "[$CmdId] BRIDGE RESTART requested — launching restarter, then exiting"
        $restarterScript = Join-Path (Split-Path -Parent $script:watcherScriptPath) "restarter.ps1"
        if (Test-Path $restarterScript) {
            try {
                $restarterProc = Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$restarterScript`"",
                    "-OldPID", [string]$PID,
                    "-WatcherPath", "`"$script:watcherScriptPath`"",
                    "-LogFile", "`"$script:logFile`""
                ) -PassThru
                Log "[$CmdId] Restarter launched PID=$($restarterProc.Id)"
            } catch {
                Log "[$CmdId] Failed to launch restarter: $($_.Exception.Message) — guardian fallback"
            }
        }
        Reset-QueueToIdle -Path $script:queueFile
        $restartRes = New-CommandResult -CmdId $CmdId -ExitCode 0 -Stdout "Bridge restarting..."
        Write-CommandResult -Result $restartRes -Directory $script:baseDir
        try { Remove-Item (Join-Path $script:baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
        exit 0
    }
    if ($Cmd -eq "__BRIDGE_STOP__") {
        Log "[$CmdId] BRIDGE STOP requested - exiting permanently"
        $script:inflight = @{}
        Reset-QueueToIdle -Path $script:queueFile
        $stopRes = New-CommandResult -CmdId $CmdId -ExitCode 0 -Stdout "Bridge stopped"
        Write-CommandResult -Result $stopRes -Directory $script:baseDir
        try { Remove-Item (Join-Path $script:baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
        exit 0
    }
    return $false
}
