#Requires -Version 5.0 -RunAsAdministrator
# Re-register all BridgeCluster tasks using direct file paths (no encoded commands)
# Auto-detects bridge root from script location. Portable across machines.
$ErrorActionPreference = "Continue"
$clusterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeBase = Split-Path -Parent $clusterDir

$workers = @(
    @{ name = "file";     desc = "File operations worker" }
    @{ name = "registry"; desc = "Registry operations worker" }
    @{ name = "process";  desc = "Process operations worker" }
    @{ name = "network";  desc = "Network operations worker" }
    @{ name = "system";   desc = "System operations worker" }
    @{ name = "wsl";      desc = "WSL/Linux operations worker" }
)

function Log { param([string]$m)
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | $m"
}

$templatePath = Join-Path $clusterDir "worker_template.ps1"
$schedulerPath = Join-Path $clusterDir "master_scheduler.ps1"

# Re-register workers
Log "=== Re-registering workers (file-based) ==="
foreach ($w in $workers) {
    $taskName = "BridgeCluster-$($w.name)"
    $workerName = "$($w.name)_bridge"

    # Unregister if exists
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue; Log "  Unregistered: $taskName" } catch {}

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$templatePath`" -WorkerName $workerName -BridgeBase `"$bridgeBase`""
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Priority 7
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Log "  Registered: $taskName (file-based)"
}

# Re-register scheduler
Log "=== Registering scheduler (file-based) ==="
$schedulerTaskName = "BridgeCluster-Scheduler"
try { Unregister-ScheduledTask -TaskName $schedulerTaskName -Confirm:$false -ErrorAction SilentlyContinue; Log "  Unregistered: $schedulerTaskName" } catch {}

$schedAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$schedulerPath`" -BridgeBase `"$bridgeBase`""
$schedPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$schedSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Priority 7
Register-ScheduledTask -TaskName $schedulerTaskName -Action $schedAction -Principal $schedPrincipal -Settings $schedSettings -Force | Out-Null
Log "  Registered: $schedulerTaskName (file-based)"

# Enable and start all
Log "=== Starting all tasks ==="
foreach ($w in $workers) {
    $taskName = "BridgeCluster-$($w.name)"
    try { Start-ScheduledTask -TaskName $taskName; Log "  Started: $taskName" } catch { Log "  FAILED: $taskName - $_" }
}
try { Start-ScheduledTask -TaskName $schedulerTaskName; Log "  Started: $schedulerTaskName" } catch { Log "  FAILED: $schedulerTaskName - $_" }

Log "=== Done ==="
