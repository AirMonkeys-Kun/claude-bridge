#Requires -Version 5.0
$ErrorActionPreference = "Continue"

Write-Host "=== 清理旧的 _bridge 后缀 Scheduled Tasks ===" -ForegroundColor Cyan

$oldTasks = @(
    "BridgeCluster-file_bridge"
    "BridgeCluster-network_bridge"
    "BridgeCluster-process_bridge"
    "BridgeCluster-registry_bridge"
    "BridgeCluster-system_bridge"
    "BridgeCluster-wsl_bridge"
)

foreach ($taskName in $oldTasks) {
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host "  ++ $taskName removed" -ForegroundColor Green
        } else {
            Write-Host "  -- $taskName not found" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  !! $taskName : $_" -ForegroundColor Yellow
    }
}

Write-Host "=== Verifying remaining bridge tasks ==="
Get-ScheduledTask -TaskName "BridgeCluster-*" | Format-Table TaskName, State -AutoSize
