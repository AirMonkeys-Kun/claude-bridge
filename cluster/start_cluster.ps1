#Requires -Version 5.0 -RunAsAdministrator
<#
 Claude Bridge Cluster — Start All Workers + Scheduler v1
 Creates worker directories, registers scheduled tasks, starts everything.
 Run this as Administrator (or SYSTEM).
#>

$ErrorActionPreference = "Continue"
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$bridgeBase = Split-Path -Parent $scriptPath  # Auto-detected bridge root
$clusterDir = $scriptPath
$templatePath = Join-Path $clusterDir "worker_template.ps1"
$schedulerPath = Join-Path $clusterDir "master_scheduler.ps1"
$stopScriptPath = Join-Path $clusterDir "stop_cluster.ps1"
$utf8 = [System.Text.UTF8Encoding]::new($false)

# ── Worker definitions ──
$workers = @(
    @{ name = "file";     desc = "File operations worker" }
    @{ name = "registry"; desc = "Registry operations worker" }
    @{ name = "process";  desc = "Process operations worker" }
    @{ name = "network";  desc = "Network operations worker" }
    @{ name = "system";   desc = "System operations worker" }
    @{ name = "wsl";      desc = "WSL/Linux operations worker" }
)

function Write-Text { param([string]$path, [string]$content)
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try { [System.IO.File]::WriteAllText($path, $content, $utf8); return }
        catch { if ($i -eq $retries - 1) { throw }; Start-Sleep -Milliseconds 100 }
    }
}

function Log { param([string]$m)
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | $m"
}

# ── Step 1: Create worker directories ──
Log "=== Creating worker directories ==="
foreach ($w in $workers) {
    $workerDir = Join-Path $clusterDir "$($w.name)_bridge"
    if (-not (Test-Path $workerDir)) {
        New-Item -Path $workerDir -ItemType Directory -Force | Out-Null
        Log "  Created: $($w.name)_bridge"
    } else {
        Log "  Exists: $($w.name)_bridge"
    }
}

# ── Step 2: Create stop script ──
Log "=== Writing stop_cluster.ps1 ==="
$stopContent = @"
`$ErrorActionPreference = "Stop"
`$clusterDir = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$workers = @("file","registry","process","network","system","wsl")
Write-Host "=== Stopping bridge cluster ==="
# Unregister scheduled tasks
foreach (`$w in `$workers) {
    `$taskName = "BridgeCluster-`$w"
    try { Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue; Write-Host "  Removed task: `$taskName" } catch {}
}
try { Unregister-ScheduledTask -TaskName "BridgeCluster-Scheduler" -Confirm:`$false -ErrorAction SilentlyContinue; Write-Host "  Removed task: BridgeCluster-Scheduler" } catch {}
# Kill any lingering processes
foreach (`$w in `$workers) {
    `$lockFile = Join-Path `$clusterDir "`${w}_bridge\.watcher.lock"
    if (Test-Path `$lockFile) {
        try {
            `$pid = [int]([System.IO.File]::ReadAllText(`$lockFile, [System.Text.UTF8Encoding]::new(`$false)).Trim())
            try { Stop-Process -Id `$pid -Force -ErrorAction SilentlyContinue; Write-Host "  Killed `$w worker PID=`$pid" } catch {}
        } catch {}
    }
}
# Kill scheduler
`$schedLock = Join-Path `$clusterDir ".scheduler_heartbeat"
# Scheduler doesn't have a lock file, find by process name
Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Where-Object { `$_.CommandLine -match "master_scheduler" } | ForEach-Object { Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue; Write-Host "  Killed scheduler PID=`$(`$_.Id)" }
Write-Host "=== Cluster stopped ==="
"@
Write-Text $stopScriptPath $stopContent
Log "Stop script written"

# ── Step 3: Kill any existing cluster processes ──
Log "=== Cleaning up existing cluster processes ==="
foreach ($w in $workers) {
    $lockFile = Join-Path $clusterDir "$($w.name)_bridge\.watcher.lock"
    if (Test-Path $lockFile) {
        try {
            $oldPid = [int]([System.IO.File]::ReadAllText($lockFile, $utf8).Trim())
            try { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue; Log "  Killed old $($w.name) worker PID=$oldPid" } catch { Log "  No process for $($w.name) PID=$oldPid" }
        } catch {}
        try { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue } catch {}
    }
    # Reset worker queue
    $qFile = Join-Path $clusterDir "$($w.name)_bridge\queue.txt"
    try { Write-Text $qFile '{"state":"idle","cmd_id":"","command":"","type":""}' } catch {}
}

# ── Step 4: Register scheduled tasks for each worker ──
Log "=== Registering worker scheduled tasks (SYSTEM, file-based) ==="

foreach ($w in $workers) {
    $taskName = "BridgeCluster-$($w.name)"
    $workerName = "$($w.name)_bridge"

    # Unregister if exists
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

    # File-based: pass -WorkerName and -BridgeBase as arguments.
    # BridgeBase can be omitted once worker_template.ps1 auto-detects from $PSScriptRoot.
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$templatePath`" -WorkerName $workerName -BridgeBase `"$bridgeBase`""
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Priority 7
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Log "  Registered: $taskName (SYSTEM, $($w.name))"
}

# ── Step 5: Register scheduler task ──
Log "=== Registering scheduler task (SYSTEM, file-based) ==="
$schedulerTaskName = "BridgeCluster-Scheduler"
try { Unregister-ScheduledTask -TaskName $schedulerTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

$schedAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$schedulerPath`" -BridgeBase `"$bridgeBase`""
$schedPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$schedSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Priority 7
Register-ScheduledTask -TaskName $schedulerTaskName -Action $schedAction -Principal $schedPrincipal -Settings $schedSettings -Force | Out-Null
Log "  Registered: $schedulerTaskName (SYSTEM)"

# ── Step 6: Start all tasks ──
Log "=== Starting all workers ==="
foreach ($w in $workers) {
    $taskName = "BridgeCluster-$($w.name)"
    try {
        Start-ScheduledTask -TaskName $taskName
        Log "  Started: $taskName"
    } catch { Log "  FAILED to start $taskName : $_" }
}

Log "=== Starting scheduler ==="
try {
    Start-ScheduledTask -TaskName $schedulerTaskName
    Log "  Started: $schedulerTaskName"
} catch { Log "  FAILED to start $schedulerTaskName : $_" }

# ── Step 7: Wait for heartbeats ──
Log "=== Waiting for worker heartbeats (5s) ==="
Start-Sleep -Seconds 5

foreach ($w in $workers) {
    $hbFile = Join-Path $clusterDir "$($w.name)_bridge\.watcher_heartbeat"
    $lockFile = Join-Path $clusterDir "$($w.name)_bridge\.watcher.lock"
    $hb = ""
    $pid = ""
    if (Test-Path $hbFile) { try { $hb = [System.IO.File]::ReadAllText($hbFile, $utf8).Trim() } catch {} }
    if (Test-Path $lockFile) { try { $pid = [System.IO.File]::ReadAllText($lockFile, $utf8).Trim() } catch {} }
    Log "  $($w.name): PID=$pid HB=$hb"
}

$schedHbFile = Join-Path $clusterDir ".scheduler_heartbeat"
$schedHb = ""
if (Test-Path $schedHbFile) { try { $schedHb = [System.IO.File]::ReadAllText($schedHbFile, $utf8).Trim() } catch {} }
Log "  Scheduler: HB=$schedHb"

Log "=== Cluster start complete ==="
Log "Master queue: $(Join-Path $clusterDir master_queue.txt)"
