# ══════════════════════════════════════════════════════════════════
# Self-upgrade handler — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Test-SelfUpgrade {
    <#.SYNOPSIS Check if watcher.ps1 has changed on disk and trigger graceful restart.#>
    $script:selfUpgradeCounter++
    if ($script:selfUpgradeCounter -ge $script:selfUpgradeCheckInterval) {
        $script:selfUpgradeCounter = 0
        try {
            $currentWrite = (Get-Item $script:watcherScriptPath).LastWriteTime
            if ($currentWrite -gt $script:watcherScriptLastWrite) {
                Log "[SELF-UPGRADE] watcher.ps1 changed on disk — initiating graceful restart"
                Write-Text -path $script:restartFlagFile -content ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"))
                $restartCmd = @{
                    state = "pending"
                    cmd_id = "__SELF_UPGRADE_$(Get-Date -Format 'yyyyMMddHHmmss')__"
                    type = "__BRIDGE_RESTART__"
                    command = ""
                    timeout = 10
                }
                Write-Text -path $script:queueFile -content ($restartCmd | ConvertTo-Json -Compress)
            }
        } catch {
            Log "[SELF-UPGRADE] Check failed: $_"
        }
    }
}
