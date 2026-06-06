# ══════════════════════════════════════════════════════════════════
# The Invoke-PollInflight handler — extracted from watcher.ps1 V22
# ══════════════════════════════════════════════════════════════════

function Invoke-PollInflight {
    <#.SYNOPSIS Check for completed async dispatch results and reset queue if all done.#>
    $completedCount = Check-InflightResults
    if ($completedCount -gt 0 -and (Get-InflightCount) -eq 0) {
        $idleCheck = Read-Json -path $script:queueFile
        if ($idleCheck -and ($idleCheck.state -eq "running" -or $idleCheck.state -eq "blocked")) {
            Reset-QueueToIdle -Path $script:queueFile
            Log "[INFLIGHT] All commands completed — queue reset to idle"
        }
    }
}
