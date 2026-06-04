<#
.SYNOPSIS
    Claude Bridge V17 — 完整重启
.DESCRIPTION
    V17 (2026-06-04): ScriptBlock in-process fast path, scheduler (Named Pipe + RunspacePool).
    Supports both Scheduled Task and direct Start-Process watcher launch.
    5 active workers + 1 scheduler: file_bridge, process_bridge, system_bridge, wsl_bridge, user_bridge.
    2 offline workers: network_bridge, registry_bridge (no worker.ps1).
#>

$ErrorActionPreference = "Continue"
$utf8 = New-Object System.Text.UTF8Encoding $false
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$watcherDir = Join-Path $root "watcher"
$clusterDir = Join-Path $root "cluster"

$activeWorkers = @("file_bridge", "process_bridge", "system_bridge", "wsl_bridge", "user_bridge")
$script:restartAttempts = 0
$script:maxRestartAttempts = 3

function Log($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | $m"
}

function Read-File($path) {
    if (-not (Test-Path $path)) { return $null }
    try { return [System.IO.File]::ReadAllText($path, $utf8).Trim() } catch { return $null }
}

function Check-File($dir, $names) {
    foreach ($n in $names) {
        $v = Read-File (Join-Path $dir $n)
        if ($v) { return $v }
    }
    return $null
}

# ======================================================
# Step 1: Kill stale processes
# ======================================================
Log "=== Step 1: Kill stale processes ==="

$allPids = @()
foreach ($dir in @($watcherDir) + (Get-ChildItem $clusterDir -Directory | ForEach-Object { $_.FullName })) {
    foreach ($lockName in @(".watcher.lock", ".lock")) {
        $pidStr = Read-File (Join-Path $dir $lockName)
        if ($pidStr -match '^\d+$') {
            $allPids += [int]$pidStr
            Log "  Found PID=$pidStr in $(Split-Path $dir -Leaf)\$lockName"
        }
    }
}

$allPids = $allPids | Select-Object -Unique
foreach ($procId in $allPids) {
    taskkill /F /PID $procId 2>$null
    Log "  KILLED PID=$procId"
}

Start-Sleep -Seconds 2
Log "  Kill phase done ($($allPids.Count) PIDs killed from lock files)"

# Fallback: kill by process name/pattern (catches processes whose lock files were already cleaned)
Log "  Fallback: killing bridge-related processes by name..."
$killedByName = 0
try {
    $bridgeProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue
    foreach ($bp in $bridgeProcs) {
        try {
            $cmdLine = $bp.CommandLine
            if ($cmdLine -match 'worker_template|worker\.ps1|watcher\.ps1|_bridge.*worker|BridgeCluster') {
                Stop-Process -Id $bp.ProcessId -Force -ErrorAction SilentlyContinue
                $killedByName++
                Log "  KILLED by name: PID=$($bp.ProcessId)"
            }
        } catch {}
    }
} catch {}
if ($killedByName -eq 0) {
    Log "  No bridge processes found by name (already dead or different naming)"
}
Start-Sleep -Seconds 2

# ======================================================
# Step 2: Clean artifacts
# ======================================================
Log "=== Step 2: Clean artifacts ==="

# Watcher
foreach ($name in @(".watcher.lock", ".lock", ".watcher_heartbeat", ".heartbeat", "startup_marker.json")) {
    $f = Join-Path $watcherDir $name
    if (Test-Path $f) { Remove-Item $f -Force; Log "  DEL watcher\$name" }
}
# Clean stale result/progress files
Get-ChildItem "$watcherDir\r_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force
    Log "  DEL watcher\$(Split-Path $_.FullName -Leaf)"
}
Get-ChildItem "$watcherDir\r_*_progress.json" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force
    Log "  DEL watcher\$(Split-Path $_.FullName -Leaf)"
}
$idleQueue = '{"state":"idle","cmd_id":"","command":"","type":""}'
[System.IO.File]::WriteAllText((Join-Path $watcherDir "queue.txt"), $idleQueue, $utf8)
Log "  watcher\queue.txt = idle"

# Workers
# Workers — include all 7 (5 active + 2 offline)
$allWorkers = @("file_bridge", "process_bridge", "system_bridge", "wsl_bridge", "user_bridge", "network_bridge", "registry_bridge")
$activeWorkers = @("file_bridge", "process_bridge", "system_bridge", "wsl_bridge", "user_bridge")
foreach ($dir in $allWorkers) {
    foreach ($name in @(".watcher.lock", ".lock", ".watcher_heartbeat", ".heartbeat")) {
        $f = Join-Path $clusterDir "$dir\$name"
        if (Test-Path $f) { Remove-Item $f -Force }
    }
    Get-ChildItem (Join-Path $clusterDir $dir) -Filter "r_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force
    }
    $qPath = Join-Path $clusterDir "$dir\queue.txt"
    [System.IO.File]::WriteAllText($qPath, $idleQueue, $utf8)
}
Log "  Worker artifacts cleaned"

# Master queue
[System.IO.File]::WriteAllText((Join-Path $clusterDir "master_queue.txt"),
    '{"state":"idle","cmd_id":"","channel":"","command":"","type":""}', $utf8)
Log "  master_queue.txt reset"

# ======================================================
# Step 3: Start watcher (with retry)
# ======================================================
Log "=== Step 3: Start watcher ==="

$watcherScript = Join-Path $watcherDir "watcher.ps1"
$debugLog = Join-Path $watcherDir "startup_debug.log"
$debugErr = Join-Path $watcherDir "startup_debug_err.log"

function Start-WatcherOnce {
    param([int]$Attempt)
    foreach ($f in @($debugLog, $debugErr)) { if (Test-Path $f) { Remove-Item $f -Force } }
    Log "  Attempt $Attempt..."

    # Clear stale heartbeat/lock so fresh watcher writes its own
    foreach ($name in @(".watcher.lock", ".lock", ".watcher_heartbeat", ".heartbeat")) {
        $f = Join-Path $watcherDir $name
        if (Test-Path $f) { Remove-Item $f -Force }
    }

    # METHOD 1: Scheduled Task
    try {
        $task = Get-ScheduledTask -TaskName "BridgeCluster-watcher" -ErrorAction SilentlyContinue
        if ($task) {
            Start-ScheduledTask -TaskName "BridgeCluster-watcher"
            Log "  [METHOD 1] Started via Scheduled Task (BridgeCluster-watcher)"
            return $true
        }
    } catch { Log "  [METHOD 1] failed: $_" }

    # METHOD 2: Direct Start-Process
    try {
        $wrapperLines = @()
        $wrapperLines += '$ErrorActionPreference = "Continue"'
        $wrapperLines += 'try {'
        $wrapperLines += "    . `"$watcherScript`" *> `"$debugLog`""
        $wrapperLines += '    $exitCode = $LASTEXITCODE'
        $wrapperLines += "    `$null | Out-File `"$debugErr`" -Encoding UTF8"
        $wrapperLines += '} catch {'
        $wrapperLines += "    `$_ | Out-File `"$debugErr`" -Encoding UTF8"
        $wrapperLines += '    exit 1'
        $wrapperLines += '}'
        $wrapperLines += "exit `$exitCode"
        $wrapperPath = Join-Path $watcherDir "_launch_wrapper.ps1"
        [System.IO.File]::WriteAllText($wrapperPath, ($wrapperLines -join "`r`n"), $utf8)
        Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $wrapperPath
        )
        Log "  [METHOD 2] Launched via wrapper"
        return $true
    } catch { Log "  [METHOD 2] FAILED: $_" }

    return $false
}

function Wait-HealthyHeartbeat {
    param([int]$MaxWaitSeconds = 12)
    $started = Get-Date
    $lastHb = ""
    $stableCount = 0
    while ((Get-Date) -lt $started.AddSeconds($MaxWaitSeconds)) {
        Start-Sleep -Milliseconds 500
        $hb = Check-File $watcherDir @(".watcher_heartbeat", ".heartbeat")
        if ($hb -and $hb -ne $lastHb) {
            $lastHb = $hb
            $stableCount++
            if ($stableCount -ge 4) {
                Log "  Heartbeat stable after $([int]((Get-Date)-$started).TotalSeconds)s: $hb"
                return $true
            }
        }
    }
    return $false
}

$watcherStarted = $false
for ($attempt = 1; $attempt -le $script:maxRestartAttempts; $attempt++) {
    $ok = Start-WatcherOnce -Attempt $attempt
    if (-not $ok) {
        Log "  Failed to launch watcher on attempt $attempt"
        continue
    }
    if (Wait-HealthyHeartbeat -MaxWaitSeconds 12) {
        $watcherStarted = $true
        break
    }
    Log "  Watcher did not stabilize on attempt $attempt — retrying..."
}

if (-not $watcherStarted) {
    Log "  [FATAL] Watcher failed to start after $script:maxRestartAttempts attempts"
    if (Test-Path $debugErr) {
        $errText = [System.IO.File]::ReadAllText($debugErr, $utf8)
        Log "  STDERR: $errText"
    }
    if (Test-Path $debugLog) {
        $logText = [System.IO.File]::ReadAllText($debugLog, $utf8)
        Log "  STDOUT (first 2000 chars):"
        ($logText.Substring(0, [Math]::Min(2000, $logText.Length)) -split "`r`n|`n") | ForEach-Object { Log "    | $_" }
    }
}

# ======================================================
# Step 4: Start scheduler (Named Pipe IPC + parallel dispatch)
# ======================================================
Log "=== Step 4: Start scheduler ==="

$schedulerScript = Join-Path $clusterDir "scheduler.ps1"
if (Test-Path $schedulerScript) {
    # Kill any stale scheduler
    $schedLockPath = Join-Path $clusterDir ".scheduler.lock"
    if (Test-Path $schedLockPath) { Remove-Item $schedLockPath -Force }
    $schedHbPath = Join-Path $clusterDir ".scheduler_heartbeat"
    if (Test-Path $schedHbPath) { Remove-Item $schedHbPath -Force }

    Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $schedulerScript,
        "-ClusterDir", $clusterDir
    )
    Log "  Scheduler launched (Named Pipe + RunspacePool parallel dispatch)"

    # Wait for scheduler heartbeat
    $schedOk = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path (Join-Path $clusterDir ".heartbeat")) {
            try {
                $shb = [System.IO.File]::ReadAllText((Join-Path $clusterDir ".heartbeat"), $utf8).Trim()
                if ($shb) { $schedOk = $true; Log "  Scheduler heartbeat OK: $shb"; break }
            } catch {}
        }
    }
    if (-not $schedOk) {
        Log "  [WARN] Scheduler heartbeat not detected — it may have crashed or uses different naming"
    }
} else {
    Log "  [SKIP] scheduler.ps1 not found at $schedulerScript"
}

# ======================================================
# Step 5: Start workers
# ======================================================
Log "=== Step 4: Start/verify workers ==="

# Try Scheduled Tasks first
try {
    $tasks = Get-ScheduledTask -TaskPath "\" | Where-Object { $_.TaskName -like "BridgeCluster-*" -and $_.TaskName -ne "BridgeCluster-Scheduler" -and $_.TaskName -ne "BridgeCluster-watcher" }
    if ($tasks -and $tasks.Count -gt 0) {
        foreach ($t in $tasks) {
            Start-ScheduledTask -TaskName $t.TaskName 2>$null
            Log "  [SCHTASK] $($t.TaskName) start signal sent"
        }
    } else {
        Log "  [SCHTASK] No BridgeCluster-* tasks found"
    }
} catch {
    Log "  [SCHTASK] Error: $_"
}

# Wait briefly, then start any worker that didn't come up via direct launch
Start-Sleep -Seconds 3
foreach ($w in $activeWorkers) {
    $hb = Check-File (Join-Path $clusterDir $w) @(".heartbeat", ".watcher_heartbeat")
    if ($hb) {
        Log "  $w : already alive via schtask (HB=$hb)"
        continue
    }
    $workerScript = Join-Path $clusterDir "$w\worker.ps1"
    if (Test-Path $workerScript) {
        Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $workerScript,
            "-WorkerDir", (Join-Path $clusterDir $w)
        )
        Log "  [DIRECT] $w launching..."
    } else {
        Log "  [DIRECT] $w SKIP (no worker.ps1)"
    }
}

# ======================================================
# Step 6: Verify
# ======================================================
Log "=== Step 6: Verify (waiting 12s) ==="
Start-Sleep -Seconds 12

$allOk = $true

# -- Watcher --
$foundWatcherHb = Check-File $watcherDir @(".watcher_heartbeat", ".heartbeat")
$foundWatcherLock = Check-File $watcherDir @(".watcher.lock", ".lock")

if ($foundWatcherHb) {
    Log "  WATCHER: PID=$foundWatcherLock HB=$foundWatcherHb [OK]"
} else {
    Log "  WATCHER: [NO HEARTBEAT]"
    if (Test-Path $debugErr) {
        $errText = [System.IO.File]::ReadAllText($debugErr, $utf8)
        if ($errText.Trim().Length -gt 0) {
            Log "  WATCHER STDERR: $errText"
        } else {
            Log "  WATCHER STDERR: (empty)"
        }
    }
    if (Test-Path $debugLog) {
        $logText = [System.IO.File]::ReadAllText($debugLog, $utf8)
        if ($logText.Trim().Length -gt 0) {
            Log "  WATCHER STDOUT/LOG (first 2000 chars):"
            $logText.Substring(0, [Math]::Min(2000, $logText.Length)) -split "`r`n|`n" | ForEach-Object {
                Log "    | $_"
            }
        } else {
            Log "  WATCHER STDOUT: (empty)"
        }
    }
    $allOk = $false
}

# -- Scheduler --
$foundSchedHb = Check-File $clusterDir @(".heartbeat", ".scheduler_heartbeat")
$foundSchedLock = Check-File $clusterDir @(".scheduler.lock")
if ($foundSchedHb) {
    Log "  SCHEDULER: HB=$foundSchedHb [OK]"
} else {
    Log "  SCHEDULER: [NO HEARTBEAT] (may have crashed or using different naming)"
}

# -- Workers (check both naming conventions) --
foreach ($w in $allWorkers) {
    $foundHb = Check-File (Join-Path $clusterDir $w) @(".heartbeat", ".watcher_heartbeat")
    $foundLock = Check-File (Join-Path $clusterDir $w) @(".lock", ".watcher.lock")
    $isActive = $w -in $activeWorkers

    if ($foundHb) {
        if ($isActive) {
            Log "  $w : PID=$foundLock HB=$foundHb [OK]"
        } else {
            Log "  $w : PID=$foundLock HB=$foundHb [IDLE]"
        }
    } else {
        if ($isActive) {
            Log "  $w : [NO HEARTBEAT]"
            $allOk = $false
        } else {
            Log "  $w : [SKIP] (inactive)"
        }
    }
}

# ======================================================
# Summary
# ======================================================
Log "=== Summary ==="
if ($allOk) {
    Log "  ALL SERVICES RUNNING"
} else {
    Log "  SOME SERVICES DOWN -- see above for details"
    Log "  Check debug logs:"
    Log "    $debugLog"
    Log "    $debugErr"
}
Log "=== Done ==="
