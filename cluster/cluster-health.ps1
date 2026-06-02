#Requires -Version 5.0 -RunAsAdministrator
<#
.SYNOPSIS
    Quick health check for BridgeCluster — heartbeat, PID, multi-line test
.DESCRIPTION
    Checks all 6 workers are alive with fresh heartbeats and correct PID.
    Optionally sends a multi-line test command (-TestStdout) to process_bridge.
    Returns structured output for agent consumption.
.EXAMPLE
    # Basic health check (no bridge commands sent)
    .\cluster-health.ps1

    # Full health check with multi-line stdout test via process_bridge
    .\cluster-health.ps1 -TestStdout
#>
param([switch]$TestStdout)

$clusterDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$workerDirs = @("file_bridge","registry_bridge","process_bridge","network_bridge","system_bridge","wsl_bridge")
$healthy = 0; $unhealthy = 0

Write-Output "=== Cluster Health Check ==="
Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')"
Write-Output ""

foreach ($w in $workerDirs) {
    $lockFile = Join-Path $clusterDir "$w\.watcher.lock"
    $hbFile = Join-Path $clusterDir "$w\.watcher_heartbeat"
    $wDir = Join-Path $clusterDir $w

    $pid = "?"; $hb = "?"; $status = "???"
    $age = -1

    if (Test-Path $lockFile) {
        try { $pid = [int]([System.IO.File]::ReadAllText($lockFile, $utf8).Trim()) } catch { $pid = "err" }
    } else { $pid = "NOLOCK" }

    if (Test-Path $hbFile) {
        try {
            $hb = [System.IO.File]::ReadAllText($hbFile, $utf8).Trim()
            $hbDt = [datetime]::ParseExact($hb.Substring(0,19), 'yyyy-MM-dd HH:mm:ss', $null)
            $age = [int](((Get-Date) - $hbDt).TotalSeconds)
        } catch { $hb = "err" }
    } else { $hb = "NOHEARTBEAT" }

    # Check if PID is alive
    $procAlive = $false
    if ($pid -match '^\d+$') {
        try { $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue; if ($proc) { $procAlive = $true } } catch {}
    }

    if ($procAlive -and $age -ge 0 -and $age -lt 120) {
        $status = "HEALTHY (pid=$pid age=${age}s)"
        $healthy++
    } elseif ($procAlive -and $age -ge 120) {
        $status = "STALE (pid=$pid age=${age}s - heartbeat expired)"
        $unhealthy++
    } elseif (-not $procAlive -and $pid -match '^\d+$') {
        $status = "DEAD (pid=$pid not running)"
        $unhealthy++
    } else {
        $status = "ERROR (pid=$pid hb=$hb)"
        $unhealthy++
    }

    Write-Output ("  [{0,-17}] {1}" -f $w, $status)
}

Write-Output ""
Write-Output "Summary: $healthy healthy, $unhealthy unhealthy (out of $($workerDirs.Count))"

# Optional multi-line stdout test via process_bridge queue
if ($TestStdout) {
    Write-Output ""
    Write-Output "=== Multi-line Stdout Test (process_bridge) ==="
    $testId = "hlth_ml_$(Get-Date -Format 'HHmmss')"
    $cmdJson = @{
        state   = "pending"
        cmd_id  = $testId
        command = "Write-Output 'line 1'; Write-Output 'line 2'; Write-Output 'line 3'; Write-Output 'line 4'; Write-Output 'line 5'"
        type    = "powershell_text"
        timeout = 15
    } | ConvertTo-Json -Compress

    $qFile = Join-Path $clusterDir "process_bridge\queue.txt"
    $rFile = Join-Path $clusterDir "process_bridge\r_${testId}.json"
    $idleJson = '{"state":"idle","cmd_id":"","command":"","type":""}'

    # Write command to queue
    [System.IO.File]::WriteAllText($qFile, $cmdJson, $utf8)
    Start-Sleep -Seconds 3

    # Read result
    $lines = 0
    if (Test-Path $rFile) {
        try {
            $result = [System.IO.File]::ReadAllText($rFile, $utf8) | ConvertFrom-Json
            $lines = ($result.stdout -split "`r`n" | Where-Object { $_ -ne '' }).Count
            $captured = $result.stdout -replace "`r`n", " / "
            Write-Output "  v4 test: exit=$($result.exit_code) lines=$lines out='$captured'"
            if ($lines -eq 5) { Write-Output "  v4: PASS ✅ (all 5 lines)" }
            else { Write-Output "  v4: FAIL ❌ (expected 5, got $lines)" }
        } catch { Write-Output "  v4: result parse error: $_" }
    } else { Write-Output "  v4: no result file (timeout?)" }

    # Reset queue
    [System.IO.File]::WriteAllText($qFile, $idleJson, $utf8)

    # Cleanup result
    if (Test-Path $rFile) { Remove-Item $rFile -Force }
}
