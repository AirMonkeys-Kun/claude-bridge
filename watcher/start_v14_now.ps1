#Requires -Version 5.0
# V14 Start — no here-strings, base64 worker-launch
Write-Host "=== Claude Bridge V14 - Start ==="
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startTime = Get-Date

# Step 1: Clean stale locks
Write-Host "[1/4] Clean stale locks..."
Remove-Item "$baseDir\.watcher.lock" -Force -ErrorAction SilentlyContinue
Remove-Item "$baseDir\.watcher_heartbeat" -Force -ErrorAction SilentlyContinue
Get-ChildItem "$baseDir\r_*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
Write-Host "  OK"

# Step 2: Reset queue to idle
Write-Host "[2/4] Reset queue..."
$idleQueue = '{"state":"idle","cmd_id":"","command":"","type":""}'
[System.IO.File]::WriteAllText("$baseDir\queue.txt", $idleQueue, [System.Text.UTF8Encoding]::new($false))
Write-Host "  OK"

# Step 3: Start V14 watcher in background
Write-Host "[3/4] Start V14 watcher..."
$v14 = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $baseDir\watcher.ps1" -WindowStyle Hidden -PassThru
Write-Host "  V14 PID = $($v14.Id)"

# Step 4: Wait for heartbeat (max 15s)
Write-Host "[4/4] Wait for heartbeat..."
$ok = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep 1
    if (Test-Path "$baseDir\.watcher_heartbeat") {
        $hb = (Get-Content "$baseDir\.watcher_heartbeat" -Raw).Trim()
        if ($hb.Length -gt 10) {
            Write-Host "  OK at ${i}s: $hb"
            $ok = $true
            break
        }
    }
    Write-Host "  ${i}s waiting..."
}
if (-not $ok) {
    Write-Host "[ERROR] Watcher did not start!"
    exit 1
}

# Step 5: Write worker-launch command to queue (via base64 — no here-string parsing issues)
Write-Host "[+] Queuing worker launch command..."
$b64 = "JHdvcmtlcnMgPSBAKCdmaWxlX2JyaWRnZScsJ3Byb2Nlc3NfYnJpZGdlJywnc3lzdGVtX2JyaWRnZScsJ3dzbF9icmlkZ2UnLCd1c2VyX2JyaWRnZScpCiRjbHVzdGVyRGlyID0gJ0Q6XHplYmJpbmdvXHRvb2xzXGNsYXVkZS1icmlkZ2VcY2x1c3RlcicKZnVuY3Rpb24gU3RhcnQtT25lKCRuYW1lKSB7CiAgICAkZCA9IEpvaW4tUGF0aCAkY2x1c3RlckRpciAkbmFtZQogICAgJHMgPSBKb2luLVBhdGggJGQgJ3dvcmtlci5wczEnCiAgICAkciA9IEpvaW4tUGF0aCAkZCAncnVubmVyLnBzMScKICAgIGlmIChUZXN0LVBhdGggJHMpIHsKICAgICAgICBTdGFydC1Qcm9jZXNzIC1GaWxlUGF0aCBwb3dlcnNoZWxsLmV4ZSAtQXJndW1lbnRMaXN0ICItTm9Qcm9maWxlIC1FeGVjdXRpb25Qb2xpY3kgQnlwYXNzIC1GaWxlIGAiJHNgIiAtV29ya2VyRGlyIGAiJGRgIiIgLVdpbmRvd1N0eWxlIEhpZGRlbgogICAgICAgIFdyaXRlLUhvc3QgIiAgU1RBUlRFRCAkbmFtZSIKICAgIH0gZWxzZWlmIChUZXN0LVBhdGggJHIpIHsKICAgICAgICBTdGFydC1Qcm9jZXNzIC1GaWxlUGF0aCBwb3dlcnNoZWxsLmV4ZSAtQXJndW1lbnRMaXN0ICItTm9Qcm9maWxlIC1FeGVjdXRpb25Qb2xpY3kgQnlwYXNzIC1GaWxlIGAiJHJgIiIgLVdpbmRvd1N0eWxlIEhpZGRlbgogICAgICAgIFdyaXRlLUhvc3QgIiAgU1RBUlRFRCAkbmFtZSAocnVubmVyKSIKICAgIH0gZWxzZSB7CiAgICAgICAgV3JpdGUtSG9zdCAiICBTS0lQICRuYW1lIChubyBzY3JpcHQpIgogICAgfQp9CmZvcmVhY2ggKCR3IGluICR3b3JrZXJzKSB7IFN0YXJ0LU9uZSAkdyB9ClN0YXJ0LVNsZWVwIDMKZm9yZWFjaCAoJHcgaW4gJHdvcmtlcnMpIHsKICAgICRoYiA9IEpvaW4tUGF0aCAkY2x1c3RlckRpciAiJHdcLmhlYXJ0YmVhdCIKICAgIGlmIChUZXN0LVBhdGggJGhiKSB7CiAgICAgICAgV3JpdGUtSG9zdCAiICBbT0tdICR3OiAkKEdldC1Db250ZW50ICRoYiAtUmF3KSIKICAgIH0gZWxzZSB7CiAgICAgICAgV3JpdGUtSG9zdCAiICBbLS1dICR3OiBubyBoZWFydGJlYXQiCiAgICB9Cn0KV3JpdGUtSG9zdCAnPT09IFdvcmtlcnMgbGF1bmNoZWQgPT09Jwo="
$workerCmd = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
$queueJson = @{
    state    = "pending"
    cmd_id   = "start_workers_001"
    command  = $workerCmd
    type     = "powershell"
    timeout  = 60
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText("$baseDir\queue.txt", $queueJson, [System.Text.UTF8Encoding]::new($false))
Write-Host "  Worker launch queued (type=powershell, cmd_id=start_workers_001)"

$elapsed = [int]((Get-Date) - $startTime).TotalSeconds
Write-Host ""
Write-Host "  V14 Watcher UP, worker launch command queued"
Write-Host "  Total: ${elapsed}s"
Writ