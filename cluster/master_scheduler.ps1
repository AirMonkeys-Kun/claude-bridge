#Requires -Version 5.0
<#
 Claude Bridge Cluster — Master Scheduler v1
 ────────────────────────────────────────
 Reads master_queue.txt, routes commands to specialized workers by channel.
 Monitors worker health, collects results, supports parallel dispatch.
 Channels: file | registry | process | network | system | wsl
#>

param(
    [string]$BridgeBase = $(if (Test-Path "C:\Users\wsx\Desktop\claude-bridge") { "C:\Users\wsx\Desktop\claude-bridge" } else { throw "BridgeBase not found" })
)

$script:clusterDir = Join-Path $BridgeBase "cluster"
$script:masterQueue = Join-Path $script:clusterDir "master_queue.txt"
$script:masterLog = Join-Path $script:clusterDir "scheduler.log"
$script:heartbeatFile = Join-Path $script:clusterDir ".scheduler_heartbeat"
$script:utf8 = [System.Text.UTF8Encoding]::new($false)
$script:idleMaster = '{"state":"idle","cmd_id":"","channel":"","command":"","type":""}'
$script:workerTimeout = 30  # seconds before considering a worker dead
$script:processedIds = @{}  # track recently completed cmd_ids to avoid re-dispatch
$script:routingTable = @{
    "file"     = @{ dir="file_bridge";     desc="File operations (read/write/delete/attr)" }
    "registry" = @{ dir="registry_bridge"; desc="Registry operations (keys/values/ACLs)" }
    "process"  = @{ dir="process_bridge";  desc="Process operations (start/kill/inject)" }
    "network"  = @{ dir="network_bridge";  desc="Network operations (ports/firewall/dns)" }
    "system"   = @{ dir="system_bridge";   desc="System operations (services/tasks/config)" }
    "wsl"      = @{ dir="wsl_bridge";      desc="WSL/Linux operations (bash/files/ipc)" }
}

# ── Helpers ──
function Write-Text { param([string]$path, [string]$content)
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try { [System.IO.File]::WriteAllText($path, $content, $script:utf8); return }
        catch { if ($i -eq $retries - 1) { throw }; Start-Sleep -Milliseconds 100 }
    }
}

function Read-Json { param([string]$path)
    if (-not (Test-Path $path)) { return $null }
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            $text = [System.IO.File]::ReadAllText($path, $script:utf8)
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        } catch { if ($i -eq $retries - 1) { return $null }; Start-Sleep -Milliseconds 100 }
    }
}

function Log { param([string]$m)
    try {
        $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($script:masterLog, "$t | [SCHEDULER] $m`r`n", $script:utf8)
    } catch {}
}

function Get-WorkerStatus { param([string]$workerDir)
    $hbFile = Join-Path (Join-Path $script:clusterDir $workerDir) ".watcher_heartbeat"
    $lockFile = Join-Path (Join-Path $script:clusterDir $workerDir) ".watcher.lock"
    $alive = $false; $pid = $null; $lastHb = $null
    if (Test-Path $lockFile) {
        try { $pid = [int]([System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim()) } catch {}
    }
    if (Test-Path $hbFile) {
        try {
            $lastHb = [System.IO.File]::ReadAllText($hbFile, $script:utf8).Trim()
            $hbTime = if ($lastHb -match '[\d]{4}-[\d]{2}-[\d]{2} [\d]{2}:[\d]{2}:[\d]{2}') { [datetime]::ParseExact($matches[0], "yyyy-MM-dd HH:mm:ss", $null) } else { $null }
            if ($hbTime -and ((Get-Date) - $hbTime).TotalSeconds -lt $script:workerTimeout) { $alive = $true }
        } catch {}
    }
    return @{ alive = $alive; pid = $pid; lastHeartbeat = $lastHb }
}

function Get-ChannelFromWorkerName { param([string]$name)
    foreach ($ch in $script:routingTable.Keys) {
        if ($script:routingTable[$ch].dir -eq "${name}_bridge") { return $ch }
    }
    return $null
}

# ── Initialize ──
Log "=== Master Scheduler STARTED ==="
$existing = Read-Json -path $script:masterQueue
if (-not $existing) { Write-Text -path $script:masterQueue -content $script:idleMaster; Log "Master queue created" }
elseif ($existing.state -eq "pending") { Log "Pending command in master queue: $($existing.cmd_id)" }
else { Write-Text -path $script:masterQueue -content $script:idleMaster; Log "Master queue reset" }

Log "Ready — polling 500ms"

# ── Main Loop ──
while ($true) {
    # Heartbeat
    try { [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8) } catch {}

    Start-Sleep -Milliseconds 500
    $master = Read-Json -path $script:masterQueue
    if (-not $master) { continue }

    # ── STATUS command: report cluster health ──
    if ($master.state -eq "pending" -and $master.channel -eq "__STATUS__") {
        $cid = $master.cmd_id
        Log "[$cid] STATUS request"
        $report = @{}
        foreach ($ch in $script:routingTable.Keys) {
            $info = $script:routingTable[$ch]
            $status = Get-WorkerStatus -workerDir $info.dir
            $report[$ch] = @{
                dir = $info.dir
                desc = $info.desc
                alive = $status.alive
                pid = $status.pid
                lastHeartbeat = $status.lastHeartbeat
            }
        }
        $result = @{
            state = "done"
            cmd_id = $cid
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            workers = $report
        }
        Write-Text -path (Join-Path $script:clusterDir "r_${cid}.json") -content ($result | ConvertTo-Json -Depth 3 -Compress)
        Write-Text -path $script:masterQueue -content $script:idleMaster
        Log "[$cid] STATUS report written"
        continue
    }

    # ── Pending command: route to worker ──
    if ($master.state -eq "pending" -and $master.cmd_id -ne "" -and -not $script:processedIds.ContainsKey($master.cmd_id)) {
        $cid = $master.cmd_id
        $channel = $master.channel
        $rawCmd = $master.command
        $cmdType = if ($master.type) { $master.type } else { "powershell" }
        $timeout = if ($master.timeout -gt 0) { $master.timeout } else { 30 }

        # Validate channel
        if (-not $script:routingTable.ContainsKey($channel)) {
            Log "[$cid] Unknown channel: $channel"
            $errResult = @{state="error";cmd_id=$cid;error="Unknown channel: $channel";channel=$channel;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $script:clusterDir "r_${cid}.json") -content ($errResult | ConvertTo-Json -Compress)
            Write-Text -path $script:masterQueue -content $script:idleMaster
            continue
        }

        $workerDir = $script:routingTable[$channel].dir
        $workerQueue = Join-Path (Join-Path $script:clusterDir $workerDir) "queue.txt"

        # Check worker health
        $status = Get-WorkerStatus -workerDir $workerDir

        # Write command to worker's queue
        $workerCmd = @{
            state = "pending"
            cmd_id = $cid
            command = $rawCmd
            type = $cmdType
            timeout = $timeout
        }
        Write-Text -path $workerQueue -content ($workerCmd | ConvertTo-Json -Compress)
        Log "[$cid] Routed to $channel ($workerDir) alive=$($status.alive) pid=$($status.pid)"

        # Mark as processed so we don't re-route
        $script:processedIds[$cid] = (Get-Date)

        # Wait for result (poll worker's result file)
        $resultFile = Join-Path (Join-Path $script:clusterDir $workerDir) "r_${cid}.json"
        $maxWait = $timeout + 5
        $waited = 0
        $workerResult = $null

        while ($waited -lt $maxWait) {
            Start-Sleep -Milliseconds 500
            $waited += 0.5
            $workerResult = Read-Json -path $resultFile
            if ($workerResult -and $workerResult.cmd_id -eq $cid) { break }
        }

        if ($workerResult -and $workerResult.cmd_id -eq $cid) {
            Log "[$cid] Result from $channel: exit=$($workerResult.exit_code) out=$($workerResult.stdout.Length)chars err=$($workerResult.stderr.Length)chars"
            # Copy result to cluster result dir
            $clusterResult = $workerResult | ConvertTo-Json -Compress
            Write-Text -path (Join-Path $script:clusterDir "r_${cid}.json") -content $clusterResult
        } else {
            Log "[$cid] TIMEOUT waiting for $channel worker result"
            $timeoutResult = @{state="error";cmd_id=$cid;error="WORKER_TIMEOUT";channel=$channel;timeout=$timeout;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $script:clusterDir "r_${cid}.json") -content ($timeoutResult | ConvertTo-Json -Compress)
        }

        # Reset master queue
        $recheck = Read-Json -path $script:masterQueue
        if ($recheck -and $recheck.state -eq "pending" -and $recheck.cmd_id -ne $cid) {
            Log "[$cid] Preserving new pending $($recheck.cmd_id)"
        } else {
            Write-Text -path $script:masterQueue -content $script:idleMaster
            Log "[$cid] Master queue reset"
        }

        # Cleanup old processed IDs (keep last 100)
        if ($script:processedIds.Count -gt 100) {
            $oldest = $script:processedIds.Keys | Sort-Object { $script:processedIds[$_] } | Select-Object -First ($script:processedIds.Count - 100)
            foreach ($k in $oldest) { $script:processedIds.Remove($k) }
        }
    }
}
