<#
 V21 Unified Arch - Performance Benchmark
 -----------------------------------------
 Tests:
   1. Base round-trip latency (watcher -> pipe worker -> r_{cid}.json)
   2. Command type diff (powershell vs cmd.exe)
   3. Named Pipe direct latency (bypass watcher)
   4. Result file read speed (unique filename = no 9P cache issue)
   5. Type routing (file type)
   6. Concurrency throughput (burst 5 and 10 - V21 parallel execution)
   7. Stress test (50 sequential)
   8. V21 inflight concurrency (mixed durations - verify parallel execution)
   9. V21 throughput (sequential max rate)

 Usage: powershell -File benchmark_v21.ps1 [-BridgeBase D:\path] [-Warmup 3] [-Iterations 10]
#>

param(
    [string]$BridgeBase = "",
    [int]$Warmup = 3,
    [int]$Iterations = 10
)

if (-not $BridgeBase) { $BridgeBase = Split-Path -Parent $MyInvocation.MyCommand.Path }

$clusterDir = Join-Path $BridgeBase "cluster"
$watcherDir = Join-Path $BridgeBase "watcher"
$queueFile = Join-Path $watcherDir "queue.txt"
$poolFile = Join-Path $clusterDir ".worker_pool.json"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$results = @{}
$global:TotalOk = 0; $global:TotalFail = 0

# ---- Utilities ----
function Log($m) { Write-Host "$(Get-Date -Format 'HH:mm:ss.fff') | $m" }

function Write-File($p, $c) {
    for ($i=0; $i -lt 3; $i++) { try { [System.IO.File]::WriteAllText($p,$c,$utf8); return } catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 20 } }
}

function Read-File($p) {
    if (-not (Test-Path $p)) { return $null }
    for ($i=0; $i -lt 3; $i++) { try { return [System.IO.File]::ReadAllText($p,$utf8) } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 20 } }
}

function Read-Json($p) {
    $t = Read-File $p
    if ($t) { try { return $t | ConvertFrom-Json } catch {} }
    return $null
}

function New-CmdId { return "bmt_$(Get-Random -Maximum 99999)_$(Get-Date -Format 'HHmmssfff')" }

# ---- V21: Wait for queue idle ----
function Wait-QueueIdle {
    for ($i=0; $i -lt 100; $i++) {
        $q = Read-Json $queueFile
        if ($q -and $q.state -eq "idle") { return $true }
        Start-Sleep -Milliseconds 10
    }
    return $false
}

# ---- Poll for result file (unique filename = no 9P cache issue) ----
function Poll-Result($cmdId, $timeoutMs=15000) {
    $rFile = Join-Path $watcherDir "r_${cmdId}.json"
    $intervalMs = 5
    $maxLoops = [Math]::Floor($timeoutMs / $intervalMs)
    for ($i=0; $i -lt $maxLoops; $i++) {
        if (Test-Path $rFile) {
            $content = Read-File $rFile
            if ($content) { return $content }
        }
        Start-Sleep -Milliseconds $intervalMs
    }
    return $null
}

# ---- V21: Send command via watcher queue.txt (with idle wait) ----
function Send-ViaWatcher($cmdId, $command, $ctype="powershell", $timeout=15) {
    Wait-QueueIdle | Out-Null
    $cmdObj = @{state="pending"; cmd_id=$cmdId; command=$command; type=$ctype; timeout=$timeout} | ConvertTo-Json -Compress
    Write-File $queueFile $cmdObj
}

# ---- Send command via Named Pipe directly to a worker ----
function Send-ViaPipe($pipeName, $cmdId, $command, $ctype="powershell", $timeout=15) {
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(3000)
        $reader = New-Object System.IO.StreamReader($pipe, $utf8)
        $writer = New-Object System.IO.StreamWriter($pipe, $utf8)
        $writer.AutoFlush = $true
        $cmdJson = @{cmd_id=$cmdId; command=$command; type=$ctype; timeout=$timeout} | ConvertTo-Json -Compress
        $writer.WriteLine($cmdJson)
        $readTask = $reader.ReadLineAsync()
        if ($readTask.Wait(($timeout+5)*1000)) {
            $result = $readTask.Result
            $pipe.Close()
            return $result
        }
        $pipe.Close()
        return $null
    } catch { return $null }
}

# ---- Measure round-trip: write queue -> poll result ----
function Measure-Roundtrip($command, $ctype="powershell", $label="roundtrip") {
    $cid = New-CmdId
    $t0 = Get-Date
    Send-ViaWatcher $cid $command $ctype
    $resultJson = Poll-Result $cid
    $elapsed = [int]((Get-Date)-$t0).TotalMilliseconds
    if ($resultJson) {
        $global:TotalOk++
        $global:results[$label].times += $elapsed
        return @{ok=$true; ms=$elapsed; result=$resultJson}
    } else {
        $global:TotalFail++
        $global:results[$label].errors += $cid
        return @{ok=$false; ms=$elapsed; error="timeout"}
    }
}

# ---- Measure Named Pipe direct latency ----
function Measure-PipeDirect($pipeName, $command, $ctype="powershell", $label="pipe_direct") {
    $cid = New-CmdId
    $t0 = Get-Date
    $resultJson = Send-ViaPipe $pipeName $cid $command $ctype
    $elapsed = [int]((Get-Date)-$t0).TotalMilliseconds
    if ($resultJson) {
        $global:TotalOk++
        $global:results[$label].times += $elapsed
        return @{ok=$true; ms=$elapsed; result=$resultJson}
    } else {
        $global:TotalFail++
        $global:results[$label].errors += $cid
        return @{ok=$false; ms=$elapsed; error="pipe_fail"}
    }
}

# ==============================================================
# MAIN
# ==============================================================

Log "======================================================"
Log " V21 Unified Arch - Performance Benchmark"
Log " Bridge base: $BridgeBase"
Log " Warmup: ${Warmup} | Iterations: ${Iterations}"
Log "======================================================"

# ---- Check system status ----
Log ""
Log "--- System Status ---"
$pool = $null
if (Test-Path $poolFile) {
    $poolJson = Read-File $poolFile
    $pool = $poolJson | ConvertFrom-Json
    Log " Worker pool: $($pool.workers.Count) workers"
    foreach ($w in $pool.workers) {
        $alive = Get-Process -Id $w.pid -ErrorAction SilentlyContinue
        $status = if ($alive) { "[ALIVE]" } else { "[DEAD]" }
        Log "   $($w.id) (pipe=$($w.pipe)) PID=$($w.pid) $status"
    }
} else { Log " [FAIL] Pool file not found!" }

$watcherHb = Join-Path $watcherDir ".watcher_heartbeat"
if (Test-Path $watcherHb) {
    $hb = Read-File $watcherHb
    Log " Watcher heartbeat: $hb"
} else { Log " [FAIL] No watcher heartbeat!" }

# ---- Init result collectors ----
$testNames = @("roundtrip_echo", "roundtrip_pwd", "roundtrip_cmd", "pipe_direct", "result_read", "concurrency_5", "concurrency_10", "type_file", "stress_50", "v21_concurrent_mixed", "v21_max_throughput")
foreach ($tn in $testNames) { $global:results[$tn] = @{times=@(); errors=@()} }

# ==============================================================
# TEST 1: Base round-trip (watcher -> pipe -> worker -> r_{cid}.json)
# V21: Async dispatch, queue resets immediately after dispatch
# ==============================================================
Log ""
Log "=== Test 1: Base Round-Trip Latency (V21 async) ==="
Start-Sleep -Milliseconds 200

Log "  Warmup x${Warmup}..."
for ($i=0; $i -lt $Warmup; $i++) {
    Measure-Roundtrip "echo WARMUP_$i" "powershell" "roundtrip_echo" | Out-Null
}

Log "  Benchmark x${Iterations}..."
for ($i=0; $i -lt $Iterations; $i++) {
    $r = Measure-Roundtrip "echo BENCH_${i}_$(Get-Date -Format 'HHmmssfff')" "powershell" "roundtrip_echo"
    $status = if ($r.ok) { "$($r.ms)ms" } else { "FAIL" }
    Log "  [$($i+1)/$Iterations] echo -> ${status}"
}

# ==============================================================
# TEST 2: powershell vs cmd.exe
# ==============================================================
Log ""
Log "=== Test 2: Command Type Diff ==="
for ($i=0; $i -lt $Iterations; $i++) {
    $r = Measure-Roundtrip "Get-Location | Select-Object -ExpandProperty Path" "powershell" "roundtrip_pwd"
    Log "  [$($i+1)/$Iterations] pwd -> $(if($r.ok){'OK'}else{'FAIL'}) $($r.ms)ms"
}
for ($i=0; $i -lt $Iterations; $i++) {
    $r = Measure-Roundtrip "echo BENCH_CMD_$i & ver" "cmd" "roundtrip_cmd"
    Log "  [$($i+1)/$Iterations] cmd.exe -> $(if($r.ok){'OK'}else{'FAIL'}) $($r.ms)ms"
}

# ==============================================================
# TEST 3: Named Pipe direct latency (bypass watcher)
# ==============================================================
Log ""
Log "=== Test 3: Named Pipe Direct Latency ==="
if ($pool -and $pool.workers) {
    $firstWorker = $pool.workers | Where-Object { $_.type -eq "generic" } | Select-Object -First 1
    if (-not $firstWorker) { $firstWorker = $pool.workers[0] }
    Log "  Target worker: $($firstWorker.id) ($($firstWorker.pipe))"
    for ($i=0; $i -lt $Iterations; $i++) {
        $r = Measure-PipeDirect $firstWorker.pipe "echo PIPE_BENCH_$i" "powershell" "pipe_direct"
        Log "  [$($i+1)/$Iterations] pipe -> $(if($r.ok){'OK'}else{'FAIL'}) $($r.ms)ms"
    }
} else { Log "  SKIP - no worker pool" }

# ==============================================================
# TEST 4: r_{cmd_id}.json read speed (9P cache bypass verification)
# ==============================================================
Log ""
Log "=== Test 4: r_{cmd_id}.json Read Speed ==="
for ($i=0; $i -lt $Iterations; $i++) {
    $cid = New-CmdId
    $t0 = Get-Date
    Send-ViaWatcher $cid "echo READ_BENCH_$i" "powershell"
    $rFile = Join-Path $watcherDir "r_${cid}.json"
    $found = $false
    for ($p=0; $p -lt 15000; $p++) {
        if (Test-Path $rFile) {
            $readStart = Get-Date
            $content = Read-File $rFile
            $readEnd = Get-Date
            $totalMs = [Math]::Round(($readEnd-$t0).TotalMilliseconds, 3)
            $readOnlyMs = [Math]::Round(($readEnd-$readStart).TotalMilliseconds, 3)
            $global:results["result_read"].times += $readOnlyMs
            $found = $true
            Log "  [$($i+1)/$Iterations] total=${totalMs}ms  file_read=${readOnlyMs}ms"
            break
        }
        Start-Sleep -Milliseconds 1
    }
    if (-not $found) {
        Log "  [$($i+1)/$Iterations] TIMEOUT"
        $global:results["result_read"].errors += $cid
        $global:TotalFail++
    } else { $global:TotalOk++ }
}

# ==============================================================
# TEST 5: Type routing - file type
# ==============================================================
Log ""
Log "=== Test 5: Type Routing ==="
if ($pool -and ($pool.workers | Where-Object { $_.type -eq "file" })) {
    for ($i=0; $i -lt [Math]::Min(3, $Iterations); $i++) {
        $r = Measure-Roundtrip "echo FILE_TYPE_TEST_$i" "file" "type_file"
        Log "  file type -> $(if($r.ok){'OK'}else{'FAIL'}) $($r.ms)ms"
    }
} else { Log "  SKIP file type - no file worker in pool" }

# ==============================================================
# TEST 6: Concurrency - burst 5 and 10 commands (V21 parallel)
# V21 key test: commands execute in parallel across worker pool
# ==============================================================
Log ""
Log "=== Test 6: Concurrency Throughput (V21 parallel) ==="
$concurrencyTests = @(5, 10)
foreach ($n in $concurrencyTests) {
    $label = if ($n -eq 5) { "concurrency_5" } else { "concurrency_10" }
    Log "  Burst of $n commands (V21 parallel dispatch)..."
    $cids = @()
    $t0 = Get-Date
    for ($i=0; $i -lt $n; $i++) {
        $cid = New-CmdId
        Send-ViaWatcher $cid "echo BURST_${n}_${i}" "powershell"
        $cids += $cid
    }
    $allDone = $true
    foreach ($cid in $cids) {
        $r = Poll-Result $cid 20000
        if (-not $r) { $allDone = $false; $global:TotalFail++; $global:results[$label].errors += $cid }
        else { $global:TotalOk++ }
    }
    $totalMs = [int]((Get-Date)-$t0).TotalMilliseconds
    $global:results[$label].times += $totalMs
    $icon = if ($allDone) { "[OK]" } else { "[FAIL]" }
    if ($totalMs -gt 0) {
        Log "    ${n} commands: ${totalMs}ms total = $([Math]::Round($n/$totalMs*1000,1)) cmd/s $icon"
    } else {
        Log "    ${n} commands: ${totalMs}ms total $icon"
    }
}

# ==============================================================
# TEST 7: Stress test - 50 sequential commands
# ==============================================================
Log ""
Log "=== Test 7: Stress Test (50 sequential) ==="
$t0 = Get-Date
$ok50 = 0
for ($i=0; $i -lt 50; $i++) {
    $r = Measure-Roundtrip "echo STRESS_${i}" "powershell" "stress_50"
    if ($r.ok) { $ok50++ }
}
$total50Ms = [int]((Get-Date)-$t0).TotalMilliseconds
if ($total50Ms -gt 0) {
    Log "  $ok50/50 OK, ${total50Ms}ms total = $([Math]::Round($ok50/$total50Ms*1000,1)) cmd/s"
} else {
    Log "  $ok50/50 OK, ${total50Ms}ms total"
}

# ==============================================================
# TEST 8: V21 mixed-duration concurrency
# Submit short + long commands concurrently, verify all complete
# This tests inflight tracking with mixed execution times
# ==============================================================
Log ""
Log "=== Test 8: V21 Mixed-Duration Concurrency ==="
Log "  Submitting 5 commands with varying durations..."
$mixCids = @()
$mixDurations = @(0, 1, 2, 1, 0)  # seconds (0=instant)
$t0 = Get-Date
for ($i=0; $i -lt 5; $i++) {
    $cid = New-CmdId
    $sleepSec = $mixDurations[$i]
    if ($sleepSec -gt 0) {
        $cmd = "Start-Sleep $sleepSec; echo MIXED_DUR_${i}_done"
    } else {
        $cmd = "echo MIXED_DUR_${i}_instant"
    }
    Send-ViaWatcher $cid $cmd "powershell" 30
    $mixCids += @{cid=$cid; dur=$sleepSec}
}
$mixAllOk = $true
$mixMaxMs = 0
foreach ($m in $mixCids) {
    $pollMs = [Math]::Max(($m.dur * 1000 + 5000), 15000)
    $r = Poll-Result $m.cid $pollMs
    if ($r) {
        $rObj = $r | ConvertFrom-Json
        $elapsedMs = $rObj.duration_ms
        if ($elapsedMs -gt $mixMaxMs) { $mixMaxMs = $elapsedMs }
        Log "  $($m.cid): dur=${elapsedMs}ms (requested sleep=${m.dur}s) [OK]"
        $global:TotalOk++
    } else {
        Log "  $($m.cid): TIMEOUT (requested sleep=${m.dur}s) [FAIL]"
        $global:TotalFail++
        $global:results["v21_concurrent_mixed"].errors += $m.cid
        $mixAllOk = $false
    }
}
$totalMixMs = [int]((Get-Date)-$t0).TotalMilliseconds
$global:results["v21_concurrent_mixed"].times += $totalMixMs
$mixMinExpected = ($mixDurations | Measure-Object -Maximum).Maximum * 1000
$parallelWin = $totalMixMs -lt $mixMinExpected * 2
Log "  All 5: ${totalMixMs}ms total, max single=${mixMaxMs}ms"
if ($parallelWin) {
    Log "  [V21 OK] Total time (${totalMixMs}ms) < 2x max sleep (${mixMinExpected}ms) = PARALLEL EXECUTION"
} else {
    Log "  [V21 WARN] Total time (${totalMixMs}ms) >= 2x max sleep (${mixMinExpected}ms) = may be sequential"
}
$mixStatus = if ($mixAllOk) { "[OK]" } else { "[FAIL]" }
Log "  Result: ${mixStatus}"

# ==============================================================
# TEST 9: V21 max throughput - sequential as fast as possible
# Measure how many short commands per second V21 can process
# ==============================================================
Log ""
Log "=== Test 9: V21 Max Throughput ==="
$burstCount = 30
Log "  Sending $burstCount commands at max rate..."
$burstCids = @()
$t0 = Get-Date
for ($i=0; $i -lt $burstCount; $i++) {
    $cid = New-CmdId
    Send-ViaWatcher $cid "echo TP_$i" "powershell"
    $burstCids += $cid
}
$burstOk = 0
foreach ($cid in $burstCids) {
    $r = Poll-Result $cid 30000
    if ($r) { $burstOk++; $global:TotalOk++ }
    else { $global:TotalFail++; $global:results["v21_max_throughput"].errors += $cid }
}
$burstMs = [int]((Get-Date)-$t0).TotalMilliseconds
$global:results["v21_max_throughput"].times += $burstMs
if ($burstMs -gt 0) {
    $throughput = [Math]::Round($burstOk/$burstMs*1000, 1)
    Log "  $burstOk/$burstCount OK, ${burstMs}ms total = ${throughput} cmd/s"
} else {
    Log "  $burstOk/$burstCount OK, ${burstMs}ms total"
}

# ==============================================================
# SUMMARY
# ==============================================================
Log ""
Log "======================================================"
Log " V21 Benchmark Results Summary"
Log "======================================================"

function Stats($times) {
    if ($times.Count -eq 0) { return "N/A" }
    $avg = [Math]::Round(($times | Measure-Object -Average).Average, 1)
    $min = [Math]::Round(($times | Measure-Object -Minimum).Minimum)
    $max = [Math]::Round(($times | Measure-Object -Maximum).Maximum)
    $sorted = $times | Sort-Object
    $med = [Math]::Round($sorted[[Math]::Floor($sorted.Count/2)], 1)
    return "avg=${avg}ms med=${med}ms min=${min}ms max=${max}ms n=$($times.Count)"
}

$summaryLines = @()
foreach ($tn in $testNames) {
    $d = $global:results[$tn]
    if ($d.times.Count -gt 0) {
        $s = Stats $d.times
        $e = if ($d.errors.Count -gt 0) { " ERR=$($d.errors.Count)" } else { "" }
        $line = "  ${tn}: $s${e}"
        $summaryLines += $line
        Log $line
    }
}

Log ""
Log "  Total OK: $global:TotalOk | Total FAIL: $global:TotalFail"
Log "======================================================"

# ---- Save results ----
$reportPath = Join-Path $BridgeBase "benchmark_v21_result.json"
$report = @{
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    bridge_base = $BridgeBase
    arch = "V21"
    iterations = $Iterations
    warmup = $Warmup
    total_ok = $global:TotalOk
    total_fail = $global:TotalFail
    system_pool = if ($pool) { @{count=$pool.workers.Count; workers=$pool.workers} } else { $null }
    results = @{}
}
foreach ($tn in $testNames) {
    $d = $global:results[$tn]
    if ($d.times.Count -gt 0) {
        $avg = [Math]::Round(($d.times | Measure-Object -Average).Average, 1)
        $min = [Math]::Round(($d.times | Measure-Object -Minimum).Minimum, 1)
        $max = [Math]::Round(($d.times | Measure-Object -Maximum).Maximum, 1)
        $sorted = $d.times | Sort-Object
        $med = [Math]::Round($sorted[[Math]::Floor($sorted.Count/2)], 1)
        $report.results[$tn] = @{
            avg_ms = $avg; med_ms = $med; min_ms = $min; max_ms = $max
            n = $d.times.Count; errors = $d.errors.Count
            times = $d.times
        }
    }
}
$report | ConvertTo-Json -Depth 5 | Out-File -FilePath $reportPath -Encoding utf8 -NoNewline
Log "Report saved: $reportPath"
Log "Benchmark complete!"
