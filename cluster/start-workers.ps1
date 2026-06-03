#Requires -Version 5.0 -RunAsAdministrator
<#
.SYNOPSIS
    Start all BridgeCluster workers via Scheduled Tasks
.DESCRIPTION
    Finds BridgeCluster-* tasks, cleans stale locks/resets queues,
    starts workers, waits for heartbeats.
#>

$ErrorActionPreference = "Continue"
$clusterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false

function Log($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | $m"
}

function Read-File($path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        return [System.IO.File]::ReadAllText($path, $utf8).Trim()
    } catch {
        return $null
    }
}

function Write-File($path, $content) {
    [System.IO.File]::WriteAllText($path, $content, $utf8)
}

$workerDirs = @("file_bridge","process_bridge","system_bridge","wsl_bridge")
# 注意: network_bridge 和 registry_bridge 已从自动启动中移除
# 它们从未收到任何命令（0 结果文件），且没有代码路径会写入它们的队列
# 如需重新启用, 加回 "network_bridge","registry_bridge"
$idleJson = '{"state":"idle","cmd_id":"","command":"","type":""}'

# === Phase 1: Find existing tasks ===
Log "=== Finding BridgeCluster tasks ==="
$tasks = $null
try {
    $tasks = Get-ScheduledTask -TaskPath "\" | Where-Object { $_.TaskName -like "BridgeCluster-*" }
} catch {}

if ($tasks -eq $null -or $tasks.Count -eq 0) {
    Log "No tasks found via Get-ScheduledTask, trying schtasks"
    schtasks /query /fo csv /nh 2>$null | Out-Null
    $raw = schtasks /query /fo csv /nh 2>$null
    if ($LASTEXITCODE -eq 0) {
        Log "BridgeCluster tasks may exist"
    } else {
        Log "No BridgeCluster tasks found. Run register-workers.ps1 register first."
        exit 1
    }
} else {
    Log "Found $($tasks.Count) task(s)"
    foreach ($t in $tasks) {
        Log "  - $($t.TaskName) (State: $($t.State))"
    }
}

# === Phase 2: Clean stale locks and reset queues ===
Log "=== Cleaning stale locks ==="
foreach ($w in $workerDirs) {
    $lockFile = Join-Path $clusterDir "$w\.watcher.lock"
    if (Test-Path $lockFile) {
        $oldPid = Read-File $lockFile
        $procExists = $false
        if ($oldPid) {
            try {
                $p = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
                if ($p) { $procExists = $true }
            } catch {}
        }
        if (-not $procExists) {
            Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            Log "  Removed stale lock for $w (PID $oldPid gone)"
        } else {
            Log "  $w lock PID=$oldPid still alive, skipped"
        }
    }

    # Reset queue to idle
    $qFile = Join-Path $clusterDir "$w\queue.txt"
    if (Test-Path $qFile) {
        try {
            $qText = [System.IO.File]::ReadAllText($qFile, $utf8)
            $qObj = $qText | ConvertFrom-Json
            if ($qObj.state -ne "idle") {
                Write-File $qFile $idleJson
                Log "  Reset $w queue (was $($qObj.state))"
            }
        } catch {
            Write-File $qFile $idleJson
            Log "  Reset $w queue (parse error)"
        }
    } else {
        Write-File $qFile $idleJson
        Log "  Created $w queue"
    }
}

# Reset master queue
$masterQueue = Join-Path $clusterDir "master_queue.txt"
$masterIdle = '{"state":"idle","cmd_id":"","channel":"","command":"","type":""}'
if (Test-Path $masterQueue) {
    Write-File $masterQueue $masterIdle
    Log "  master_queue.txt reset"
}

# === Phase 3: Start workers ===
if ($tasks -ne $null -and $tasks.Count -gt 0) {
    Log "=== Starting workers via Start-ScheduledTask ==="
    foreach ($t in $tasks) {
        try {
            Start-ScheduledTask -TaskName $t.TaskName
            Log "  STARTED: $($t.TaskName)"
        } catch {
            Log "  FAILED: $($t.TaskName) : $_"
        }
    }
} else {
    Log "=== Starting workers via schtasks ==="
    foreach ($w in $workerDirs) {
        # Strip _bridge suffix for task name (BridgeCluster-file not BridgeCluster-file_bridge)
        $taskName = "BridgeCluster-" + ($w -replace '_bridge$', '')
        try {
            schtasks /run /tn $taskName
            Log "  schtasks /run $taskName"
        } catch {
            Log "  FAILED: schtasks /run $taskName"
        }
    }
}

# === Phase 4: Verify heartbeats ===
Log "=== Waiting 5s for heartbeats ==="
Start-Sleep -Seconds 5

$allOk = $true
foreach ($w in $workerDirs) {
    $hbFile = Join-Path $clusterDir "$w\.watcher_heartbeat"
    $lockFile = Join-Path $clusterDir "$w\.watcher.lock"
    $hb = Read-File $hbFile
    $lockPid = Read-File $lockFile
    if ($hb) {
        Log "  $w : PID=$lockPid HB=$hb [OK]"
    } else {
        Log "  $w : PID=$lockPid HB=$hb [NO HEARTBEAT]"
        $allOk = $false
    }
}

if ($allOk) {
    Log "=== All workers started successfully ==="
} else {
    Log "=== Some workers may not have started ==="
}

# Start scheduler if it exists
if ($tasks -ne $null) {
    foreach ($t in $tasks) {
        if ($t.TaskName -eq "BridgeCluster-Scheduler") {
            try {
                Start-ScheduledTask -TaskName "BridgeCluster-Scheduler"
                Log "  STARTED: BridgeCluster-Scheduler"
            } catch {
                Log "  FAILED: BridgeCluster-Scheduler: $_"
            }
            break
        }
    }
} else {
    schtasks /run /tn "BridgeCluster-Scheduler" 2>$null | Out-Null
}

Log "=== Done ==="
