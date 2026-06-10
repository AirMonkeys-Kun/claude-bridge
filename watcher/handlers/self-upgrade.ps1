# ══════════════════════════════════════════════════════════════════
# Self-upgrade handler — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Test-SelfUpgrade {
    <#.SYNOPSIS Check if watcher.ps1 content has changed and trigger graceful restart with cooldown + dedup.#>
    $script:selfUpgradeCounter++
    if ($script:selfUpgradeCounter -ge $script:selfUpgradeCheckInterval) {
        $script:selfUpgradeCounter = 0
        try {
            # 1. Cooldown — at most one restart per $selfUpgradeCooldown seconds
            if ($script:selfUpgradeLastTrigger) {
                $age = ((Get-Date) - $script:selfUpgradeLastTrigger).TotalSeconds
                if ($age -lt $script:selfUpgradeCooldown) {
                    return
                }
            }

            # 2. Content hash comparison (no false positives from timestamp drift)
            $currentHash = (Get-FileHash $script:watcherScriptPath).Hash
            if ($currentHash -ne $script:watcherScriptHash) {
                Log "[SELF-UPGRADE] watcher.ps1 changed (hash: $($script:watcherScriptHash.Substring(0,16))... → $($currentHash.Substring(0,16))...)"

                # 3. Queue dedup — don't pile up if upgrade already pending
                try {
                    $queue = Read-Json -path $script:queueFile
                    if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id -like "__SELF_UPGRADE_*") {
                        Log "[SELF-UPGRADE] Already queued (cmd_id=$($queue.cmd_id)) — skipping duplicate"
                        return
                    }
                } catch {
                    # Fall through — write the command anyway if queue read fails
                }

                # 4. Drain protocol (P2.3) — wait for inflight commands to complete
                $drainStart = Get-Date
                $drainMaxSec = 30
                $drainElapsed = 0
                while ((Get-InflightCount) -gt 0) {
                    $drainElapsed = [int]((Get-Date) - $drainStart).TotalSeconds
                    if ($drainElapsed -ge $drainMaxSec) {
                        Log "[SELF-UPGRADE] Drain timeout after ${drainElapsed}s — $((Get-InflightCount)) inflight still pending, forcing restart"
                        break
                    }
                    # Let the main loop process inflight completions
                    Start-Sleep -Milliseconds 200
                }

                if ((Get-InflightCount) -eq 0) {
                    $drainDuration = [int]((Get-Date) - $drainStart).TotalMilliseconds
                    Log "[SELF-UPGRADE] Inflight drained in ${drainDuration}ms — proceeding with restart"
                }

                # 5. Save inflight to disk (P1.3) — for post-restart recovery if any remain
                Save-InflightToDisk

                $script:watcherScriptHash = $currentHash
                $script:selfUpgradeLastTrigger = Get-Date
                Write-Text -path $script:restartFlagFile -content ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"))
                $restartCmd = @{
                    state = "pending"
                    cmd_id = "__SELF_UPGRADE_$(Get-Date -Format 'yyyyMMddHHmmss')__"
                    type = "__BRIDGE_RESTART__"
                    command = "__BRIDGE_RESTART__"
                    timeout = 10
                }
                Write-Text -path $script:queueFile -content ($restartCmd | ConvertTo-Json -Compress)
                Log "[SELF-UPGRADE] Restart command written (drain=${drainElapsed}s, 60s cooldown engaged)"
            }
        } catch {
            Log "[SELF-UPGRADE] Check failed: $_"
        }
    }
}
