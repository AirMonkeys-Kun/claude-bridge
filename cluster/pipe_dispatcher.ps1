#Requires -Version 5.0
<#
 pipe_dispatcher.ps1 — Named Pipe dispatcher for worker pool (V2 — PARALLEL)
 ──────────────────
 V2 (2026-06-04): Parallel dispatch via PowerShell runspaces. Each wave of
   commands is sent to all workers simultaneously, then results collected.
   Total batch time ≈ waves × (command_time + overhead), not commands × time.

 V1 (2026-06-04): Sequential — one pipe at a time.

 Usage: powershell -File pipe_dispatcher.ps1 [-BridgeBase D:\...] [-Timeout 30]
        Writes batch results to cluster/.pipe_batch_result.json
#>

param(
    [string]$BridgeBase = "",
    [int]$Timeout = 30
)

if (-not $BridgeBase) {
    $BridgeBase = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$clusterDir = Join-Path $BridgeBase "cluster"
$resultDir = Join-Path $BridgeBase "watcher"
$poolFile = Join-Path $clusterDir ".worker_pool.json"
$masterQueueFile = Join-Path $clusterDir ".pipe_master_queue.json"
$batchResultFile = Join-Path $clusterDir ".pipe_batch_result.json"
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Log($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | [DISPATCH] $m"
}

# ── Load worker pool ──
if (-not (Test-Path $poolFile)) {
    Log "ERROR: No worker pool file at $poolFile — run worker_factory.ps1 first"
    exit 1
}

$pool = Get-Content $poolFile -Raw | ConvertFrom-Json
$workers = $pool.workers
$workerCount = $workers.Count
Log "Loaded $workerCount workers from pool"

# ── Wait for master queue ──
Log "Waiting for master queue: $masterQueueFile"
while (-not (Test-Path $masterQueueFile)) {
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 50

# ── Read batch ──
try {
    $batchJson = [System.IO.File]::ReadAllText($masterQueueFile, $utf8)
    $batch = $batchJson | ConvertFrom-Json
    $commands = $batch.commands
    Log "Batch received: $($commands.Count) commands"
} catch {
    Log "ERROR reading master queue: $_"
    exit 1
}
Remove-Item $masterQueueFile -Force -ErrorAction SilentlyContinue

$total = $commands.Count
$results = @{}
$tBatchStart = Get-Date

# ═══════════════════════════════════════════════════════════
# V2: PARALLEL DISPATCH via runspaces
# Each wave sends one command to every worker simultaneously.
# All runspaces in a wave complete before the next wave starts.
# ═══════════════════════════════════════════════════════════

Log "Dispatching $total commands via Named Pipes (PARALLEL waves of $workerCount)"

$nextWorker = 0
$waveNum = 0

while ($nextWorker -lt $total) {
    $waveNum++
    $waveStart = Get-Date

    # Build runspaces for this wave (one per available worker)
    $runspaces = @()
    $waveResults = @{}

    for ($w = 0; $w -lt $workerCount -and $nextWorker -lt $total; $w++) {
        $cmd = $commands[$nextWorker]
        $worker = $workers[$w]
        $cid = $cmd.cmd_id
        $pipeName = $worker.pipe
        $pipeJson = $cmd | ConvertTo-Json -Compress
        $nextWorker++

        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({
            param($pn, $cmdJson, $to, $u8enc)
            try {
                $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
                    ".", $pn,
                    [System.IO.Pipes.PipeDirection]::InOut
                )
                $pipe.Connect(5000)
                $reader = New-Object System.IO.StreamReader($pipe, $u8enc)
                $writer = New-Object System.IO.StreamWriter($pipe, $u8enc)
                $writer.AutoFlush = $true
                $writer.WriteLine($cmdJson)

                # Read result with timeout
                $readTask = $reader.ReadLineAsync()
                if ($readTask.Wait(($to + 5) * 1000)) {
                    $resultJson = $readTask.Result
                    $pipe.Close()
                    return $resultJson
                } else {
                    $pipe.Close()
                    return '{"status":"error","error":"PIPE READ TIMEOUT"}'
                }
            } catch {
                return "{`"status`":`"error`",`"error`":`"$($_.Exception.Message -replace '"','\"')`"}"
            }
        }).AddArgument($pipeName).AddArgument($pipeJson).AddArgument($Timeout).AddArgument($utf8)

        $runspaces += @{
            ps = $ps
            handle = $ps.BeginInvoke()
            cid = $cid
            worker = $worker.id
        }
    }

    Log "Wave $waveNum : $($runspaces.Count) parallel pipe connections"

    # Wait for all runspaces in this wave to complete
    foreach ($rs in $runspaces) {
        $cid = $rs.cid
        $wid = $rs.worker

        try {
            if ($rs.handle.AsyncWaitHandle.WaitOne(($Timeout + 10) * 1000)) {
                $resultJson = $rs.ps.EndInvoke($rs.handle)
                try {
                    $result = $resultJson | ConvertFrom-Json
                    $results[$cid] = $result
                    Log "  [$cid] PIPE OK — dur=$($result.duration_ms)ms fast=$($result.fast_path) worker=$wid"
                } catch {
                    $results[$cid] = @{status="error";cmd_id=$cid;error="JSON parse failed: $_";duration_ms=0;fast_path=$false}
                    Log "  [$cid] JSON parse error"
                }
            } else {
                $rs.ps.Stop()
                $results[$cid] = @{status="error";cmd_id=$cid;error="RUNSPACE TIMEOUT";duration_ms=0;fast_path=$false}
                Log "  [$cid] RUNSPACE TIMEOUT worker=$wid"
            }
        } catch {
            $results[$cid] = @{status="error";cmd_id=$cid;error="Runspace failed: $_";duration_ms=0;fast_path=$false}
            Log "  [$cid] RUNSPACE ERROR worker=${wid} : $_"
        }
        $rs.ps.Dispose()
    }

    $waveElapsed = [int]((Get-Date) - $waveStart).TotalMilliseconds
    Log "Wave $waveNum complete: ${waveElapsed}ms"
}

$tBatchElapsed = [int]((Get-Date) - $tBatchStart).TotalMilliseconds

# ── Write batch results ──
$batchResult = @{
    total = $total
    completed = $results.Count
    batch_duration_ms = $tBatchElapsed
    waves = $waveNum
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    results = $results
}

$batchResult | ConvertTo-Json -Depth 4 | Out-File -FilePath $batchResultFile -Encoding utf8 -NoNewline
Log "Batch complete: $($results.Count)/$total results, ${tBatchElapsed}ms total, $waveNum waves"

# ── Summary ──
$pipeOk = ($results.Values | Where-Object { $_.status -eq "done" -or $_.status -eq "error" }).Count
$pipeFail = ($results.Values | Where-Object { $_.status -eq "queued" }).Count
$durs = @($results.Values | Where-Object { $_.duration_ms -gt 0 } | ForEach-Object { $_.duration_ms })
$avgDur = if ($durs.Count -gt 0) { [int](($durs | Measure-Object -Average).Average) } else { 0 }
Log "SUMMARY: pipe=$pipeOk fail=$pipeFail avg_dur=${avgDur}ms speedup=$( [math]::Round($total * $avgDur / [Math]::Max(1, $tBatchElapsed), 1) )x"
