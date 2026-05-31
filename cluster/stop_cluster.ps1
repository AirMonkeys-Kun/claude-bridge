$ErrorActionPreference = "Stop"
$clusterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$workers = @("file","registry","process","network","system","wsl")
Write-Host "=== Stopping bridge cluster ==="
# Unregister scheduled tasks
foreach ($w in $workers) {
    $taskName = "BridgeCluster-$w"
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "  Removed task: $taskName" } catch {}
}
try { Unregister-ScheduledTask -TaskName "BridgeCluster-Scheduler" -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "  Removed task: BridgeCluster-Scheduler" } catch {}
# Kill any lingering processes
foreach ($w in $workers) {
    $lockFile = Join-Path $clusterDir "${w}_bridge\.watcher.lock"
    if (Test-Path $lockFile) {
        try {
            $pid = [int]([System.IO.File]::ReadAllText($lockFile, [System.Text.UTF8Encoding]::new($false)).Trim())
            try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue; Write-Host "  Killed $w worker PID=$pid" } catch {}
        } catch {}
    }
}
# Kill scheduler
$schedLock = Join-Path $clusterDir ".scheduler_heartbeat"
# Scheduler doesn't have a lock file, find by process name
Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "master_scheduler" } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; Write-Host "  Killed scheduler PID=$($_.Id)" }
Write-Host "=== Cluster stopped ==="