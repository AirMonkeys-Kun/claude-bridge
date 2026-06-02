#Requires -Version 5.0
param([string]$ClusterDir = $(throw "ClusterDir required"))
$ErrorActionPreference = "Continue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$masterQueue = Join-Path $ClusterDir "master_queue.txt"
$logFile = Join-Path $ClusterDir "scheduler.log"
$heartbeatFile = Join-Path $ClusterDir ".heartbeat"
$idleMaster = '{"v":3,"state":"idle","c":[],"r":{}}'
$routingTable = @{
    "file"="file_bridge";"f"="file_bridge";"registry"="registry_bridge";"r"="registry_bridge"
    "process"="process_bridge";"p"="process_bridge";"network"="network_bridge";"n"="network_bridge"
    "system"="system_bridge";"s"="system_bridge";"wsl"="wsl_bridge";"w"="wsl_bridge"
    "user"="user_bridge";"u"="user_bridge"
}

function TLog($m) {
    try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($logFile,"$t | [SCHED] $m`r`n",$utf8) } catch {}
}
function WriteF($p,$c) {
    for ($i=0; $i -lt 3; $i++) { try { [System.IO.File]::WriteAllText($p,$c,$utf8); return } catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 20 } }
}
function ReadJ($p) {
    if (-not (Test-Path $p)) { return $null }
    for ($i=0; $i -lt 3; $i++) { try { $t=[System.IO.File]::ReadAllText($p,$utf8); if ([string]::IsNullOrWhiteSpace($t)) { return $null }; return ($t|ConvertFrom-Json) } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 20 } }
}

# ── V5: Rule engine ──
$ruleEnginePath = Join-Path $ClusterDir "rule_engine.ps1"
$script:reLoaded = $false
if (Test-Path $ruleEnginePath) {
    try {
        . $ruleEnginePath
        Init-RuleEngine -BridgeBase (Split-Path $ClusterDir -Parent)
        $script:reLoaded = $true
        TLog "Rule engine loaded from $ruleEnginePath"
    } catch {
        TLog "Rule engine load failed: $_"
        $script:reLoaded = $false
    }
} else {
    TLog "Rule engine not found at $ruleEnginePath"
    $script:reLoaded = $false
}

# ── Named Pipe IPC (single worker) ──
function PipeRoute($dirName, $cmdJson) {
    $pn = "Cluster_Wkr_$($dirName -replace '_bridge','')"
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pn, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(200)
        $writer = New-Object System.IO.StreamWriter($pipe)
        $reader = New-Object System.IO.StreamReader($pipe)
        $writer.AutoFlush = $true
        $writer.WriteLine($cmdJson)
        $result = $reader.ReadLine()
        $pipe.Close()
        return $result
    } catch {
        TLog "Pipe $pn fail: $($_.Exception.Message -replace '`r`n',' ')"
        return $null
    }
}

# ── Parallel dispatch: fire pipe connections to all workers at once ──
function ParallelDispatch($dispatchList) {
    $results = @{}
    if ($dispatchList.Count -eq 0) { return $results }

    # Group by worker dir (one pipe per worker at a time)
    $groups = @{}
    foreach ($d in $dispatchList) { $groups[$d.wdir] = $d }
    $workers = $groups.Keys

    # Use RunspacePool for parallel pipe calls
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $workers.Count))
    $pool.Open()
    $tasks = @{}
    foreach ($wdir in $workers) {
        $d = $groups[$wdir]
        $ps = [PowerShell]::Create()
        $ps.AddScript({ param($dn, $js) PipeRoute $dn $js }).AddArgument($wdir).AddArgument($d.cmdJson) | Out-Null
        $ps.RunspacePool = $pool
        $handle = $ps.BeginInvoke()
        $tasks[$wdir] = @{ps=$ps; handle=$handle}
    }

    # Collect results as they complete
    $remaining = @($workers)
    $deadline = (Get-Date).AddSeconds(5)
    while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $done = @()
        foreach ($wdir in $remaining) {
            $t = $tasks[$wdir]
            if ($t.handle.IsCompleted) {
                try { $rStr = $t.ps.EndInvoke($t.handle); if ($rStr) { $results[$wdir] = $rStr | ConvertFrom-Json } } catch {}
                $t.ps.Dispose()
                $done += $wdir
            }
        }
        foreach ($w in $done) { $remaining = $remaining -ne $w }
        if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 10 }
    }

    # Dispose remaining (timed out)
    foreach ($wdir in $remaining) {
        try { $tasks[$wdir].ps.Dispose() } catch {}
    }
    $pool.Dispose()
    return $results
}

# ── Events for V4 zero-sleep loop ──
$queueEvent = $null
$resultEvent = $null
$schedPipeStarted = $false
$fastQueueFile = Join-Path $ClusterDir ".fast_queue.json"

try {
    $queueEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\Cluster_Queue")
    TLog "QueueEvent OK"
} catch { TLog "QueueEvent N/A" }

try {
    $resultEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\Cluster_Result")
    TLog "ResultEvent OK"
} catch { TLog "ResultEvent N/A" }

# ── V4 Fast Pipe Server in background ──
$schedPipeName = "Cluster_Sched"
$pipeAsync = $null
try {
    $pipePs = [PowerShell]::Create()
    $null = $pipePs.AddScript({
        param($pipeName, $fqFile, $qfEventName, $rfEventName, $logF, $idleMaster)
        $u8 = [System.Text.UTF8Encoding]::new($false)
        $utf8 = $u8
        function W($m) { try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($logF,"$t | [SCHED] $m`r`n",$u8) } catch {} }
        function WF($p,$c) { for ($i=0;$i -lt 3;$i++){try{[System.IO.File]::WriteAllText($p,$c,$u8);return}catch{if($i -eq 2){throw};Start-Sleep -Milliseconds 20}}}
        function RJ($p) { if (-not (Test-Path $p)){return $null}; for($i=0;$i -lt 3;$i++){try{$t=[System.IO.File]::ReadAllText($p,$u8);if([string]::IsNullOrWhiteSpace($t)){return $null};return($t|ConvertFrom-Json)}catch{if($i -eq 2){return $null};Start-Sleep -Milliseconds 20}} }

        $qe = $null; $re = $null
        try { $qe = [System.Threading.EventWaitHandle]::OpenExisting($qfEventName) } catch {}
        try { $re = [System.Threading.EventWaitHandle]::OpenExisting($rfEventName) } catch {}
        W "PipeSrv started: $pipeName"
        while ($true) {
            try {
                $pipe = New-Object System.IO.Pipes.NamedPipeServerStream($pipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Message)
                $pipe.WaitForConnection()
                $reader = New-Object System.IO.StreamReader($pipe)
                $writer = New-Object System.IO.StreamWriter($pipe)
                $writer.AutoFlush = $true
                $cmdJson = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($cmdJson)) { $pipe.Close(); continue }

                $cmd = $cmdJson | ConvertFrom-Json
                $cid = $cmd.id

                # Write to fast queue file
                WF $fqFile $cmdJson
                # Signal scheduler
                try { if ($qe) { $qe.Set() } } catch {}

                # Wait for result on dedicated per-command event
                $resEventName = "Local\Cluster_Result_$cid"
                $resEvent = $null
                try { $resEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $resEventName) } catch {}

                # Also wait via Cluster_Result event (broader signal)
                $waited = 0; $result = $null
                while ($waited -lt 60000) {
                    # Check result file
                    $rf = Join-Path ([System.IO.Path]::GetDirectoryName($fqFile)) "r_${cid}.json"
                    $rr = RJ $rf
                    if ($rr -and $rr.id -eq $cid -and ($rr.state -eq "done" -or $rr.state -eq "error")) { $result = $rr; break }

                    # Wait for any signal (10ms timeout)
                    if ($resEvent) { $null = $resEvent.WaitOne(10) }
                    elseif ($re) { $null = $re.WaitOne(10) }
                    else { Start-Sleep -Milliseconds 10 }
                    $waited += 10
                }

                # Send result back on pipe
                if ($result) {
                    $jsonOut = $result | ConvertTo-Json -Compress
                    $writer.WriteLine($jsonOut)
                } else {
                    $writer.WriteLine('{"state":"error","id":"' + $cid + '","err":"TIMEOUT"}')
                }

                try { if ($resEvent) { $resEvent.Dispose() } } catch {}
                $pipe.Close()
            } catch { W "PipeSrv err: $($_.Exception.Message -replace '`r`n',' ')"; try { if ($pipe) { $pipe.Close() } } catch {} }
        }
    }).AddArgument($schedPipeName).AddArgument($fastQueueFile).AddArgument("Local\Cluster_Queue").AddArgument("Local\Cluster_Result").AddArgument($logFile).AddArgument($idleMaster)
    $pipeAsync = $pipePs.BeginInvoke()
    $schedPipeStarted = $true
    TLog "PipeSrv $schedPipeName background OK"
} catch { TLog "PipeSrv $schedPipeName N/A" }

# ── V4 Startup ──
TLog "=== V4 Scheduler STARTED ==="
WriteF $masterQueue $idleMaster
TLog "Ready (zero-sleep event-driven)"

$processedIds = @{}
$lastQueueContent = ""
$lastFastContent = ""
$mainLoopDelay = 0

while ($true) {
    # ── Heartbeat ──
    try { [System.IO.File]::WriteAllText($heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $utf8) } catch {}

    # ── Event-driven wait (zero sleep!) ──
    # Wait on queue event with 500ms heartbeat timeout
    if ($queueEvent) {
        $null = $queueEvent.WaitOne(500)
    } else {
        Start-Sleep -Milliseconds 100
    }

    # ── Collect commands from ALL sources ──
    $allCmds = @()

    # Source 1: Fast queue (from pipe server)
    if (Test-Path $fastQueueFile) {
        $fc = ReadJ $fastQueueFile
        if ($fc -and $fc.id -and -not $processedIds.ContainsKey($fc.id)) {
            $allCmds += @{source="fast"; cmd=$fc}
            try { [System.IO.File]::WriteAllText($fastQueueFile, "", $utf8) } catch {}
        }
    }

    # Source 2: Master queue (file-based, V3/V4)
    $master = ReadJ $masterQueue
    if ($master -and $master.v -ge 3 -and $master.state -eq "pending" -and $master.c -and $master.c.Count -gt 0) {
        foreach ($cmd in $master.c) {
            if ($cmd.id -and -not $processedIds.ContainsKey($cmd.id)) {
                $allCmds += @{source="file"; cmd=$cmd}
            }
        }
    }

    if ($allCmds.Count -eq 0) { continue }

    # ── Process STATUS command ──
    $regularCmds = @()
    foreach ($entry in $allCmds) {
        $cmd = $entry.cmd
        $ch = if ($cmd.ch) { $cmd.ch } else { $cmd.channel }
        if ($ch -eq "__STATUS__") {
            $sid = $cmd.id; $report = @{}; $uniqueDirs = @{}
            foreach ($ck in $routingTable.Keys) { $uniqueDirs[$routingTable[$ck]] = $ck }
            foreach ($dir in $uniqueDirs.Keys) {
                $chk = $uniqueDirs[$dir]
                $hbF = Join-Path $ClusterDir "$dir\.heartbeat"
                $lkF = Join-Path $ClusterDir "$dir\.lock"
                $alive = $false; $wpid = $null; $hb = $null
                if (Test-Path $lkF) { try { $wpid = [int]([System.IO.File]::ReadAllText($lkF,$utf8).Trim()) } catch {} }
                if (Test-Path $hbF) {
                    try { $hb = [System.IO.File]::ReadAllText($hbF,$utf8).Trim(); $hbT = [datetime]::ParseExact($hb,"yyyy-MM-dd HH:mm:ss.fff",$null); if (((Get-Date) - $hbT).TotalSeconds -lt 30) { $alive = $true } } catch {}
                }
                $report[$chk] = @{d=$dir; alive=$alive; pid=$wpid; hb=$hb}
            }
            WriteF (Join-Path $ClusterDir "r_${sid}.json") (@{state="done";id=$sid;ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff");wrkrs=$report} | ConvertTo-Json -Depth 2 -Compress)
            try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result_$sid"); $e.Set(); $e.Dispose() } catch {}
            try { if ($resultEvent) { $resultEvent.Set() } } catch {}
            TLog "[$sid] STATUS done"
        } else {
            $regularCmds += $entry
        }
    }

    if ($regularCmds.Count -eq 0) { WriteF $masterQueue $idleMaster; $lastQueueContent = $idleMaster; continue }

    # ── V4 PARALLEL DISPATCH ──
    $dispatchList = @()
    foreach ($entry in $regularCmds) {
        $cmd = $entry.cmd
        $cid = $cmd.id
        $channel = if ($cmd.ch) { $cmd.ch } else { $cmd.channel }
        $rawCmd = if ($cmd.c) { $cmd.c } else { $cmd.command }
        $wdir = $routingTable[$channel]
        if (-not $wdir) { TLog "[$cid] Unknown ch: $channel"; continue }
        $ctype = if ($cmd.t) { $cmd.t } else { if ($cmd.type) { $cmd.type } else { "p" } }
        $timeout = if ($cmd.to -gt 0) { $cmd.to } else { if ($cmd.timeout -gt 0) { $cmd.timeout } else { 30 } }
        $async = if ($cmd.a -eq $true -or $cmd.async -eq $true) { $true } else { $false }

        # ── V5: Apply rules before dispatch ──
        if ($script:reLoaded) {
            $ruleResult = Apply-Rules -Cmd $rawCmd -Type $ctype
            if ($ruleResult.cmd -ne $rawCmd) {
                TLog "[$cid] RULE: '$rawCmd' -> '$($ruleResult.cmd)' (rules: $($ruleResult.applied -join ','))"
                $rawCmd = $ruleResult.cmd
            }
            if ($ruleResult.type -ne $ctype) {
                TLog "[$cid] RULE type: $ctype -> $($ruleResult.type)"
                $ctype = $ruleResult.type
            }
        }

        $cmdJson = (@{id=$cid;c=$rawCmd;t=$ctype;to=$timeout} | ConvertTo-Json -Compress)
        $processedIds[$cid] = (Get-Date)

        $dispatchList += @{cid=$cid; wdir=$wdir; cmdJson=$cmdJson; channel=$channel; async=$async; timeout=$timeout; source=$entry.source}
    }

    if ($dispatchList.Count -eq 0) { WriteF $masterQueue $idleMaster; continue }

    # ── PARALLEL: fire all pipe connections at once ──
    TLog "DISPATCH $($dispatchList.Count) cmds to $((@($dispatchList | ForEach-Object {$_.wdir} | Select-Object -Unique)).Count) workers"

    # Group by worker (sequential within same worker, parallel across workers)
    $workerGroups = @{}
    foreach ($d in $dispatchList) {
        if (-not $workerGroups.ContainsKey($d.wdir)) { $workerGroups[$d.wdir] = @() }
        $workerGroups[$d.wdir] += $d
    }

    # Launch parallel pipe calls (one per unique worker)
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(1, $workerGroups.Count))
    $pool.Open()
    $pipeTasks = @{}
    foreach ($wdir in $workerGroups.Keys) {
        $dlist = $workerGroups[$wdir]
        # Take first command for this worker (sequential within same worker)
        $first = $dlist[0]
        $ps = [PowerShell]::Create()
        $ps.AddScript({ param($dn, $js) PipeRoute $dn $js }).AddArgument($wdir).AddArgument($first.cmdJson) | Out-Null
        $ps.RunspacePool = $pool
        $handle = $ps.BeginInvoke()
        $pipeTasks[$wdir] = @{ps=$ps; handle=$handle; items=$dlist}
    }

    # Collect pipe results as they complete
    $pipeResults = @{}
    $remaining = @($workerGroups.Keys)
    $pDeadline = (Get-Date).AddSeconds(5)
    while ($remaining.Count -gt 0 -and (Get-Date) -lt $pDeadline) {
        $done = @()
        foreach ($wdir in $remaining) {
            $t = $pipeTasks[$wdir]
            if ($t.handle.IsCompleted) {
                try { $rStr = $t.ps.EndInvoke($t.handle); if ($rStr) { $pipeResults[$wdir] = $rStr | ConvertFrom-Json } } catch {}
                $t.ps.Dispose()
                $done += $wdir
            }
        }
        foreach ($w in $done) { $remaining = $remaining -ne $w }
        if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 5 }
    }
    # Dispose timed-out
    foreach ($wdir in $remaining) { try { $pipeTasks[$wdir].ps.Dispose() } catch {} }
    $pool.Dispose()

    # ── Process results ──
    $maxTimeout = 0
    foreach ($d in $dispatchList) { if (-not $pipeResults.ContainsKey($d.wdir)) { $maxTimeout = [Math]::Max($maxTimeout, $d.timeout) } }

    $fileFallbackDeadline = if ($maxTimeout -gt 0) { (Get-Date).AddSeconds($maxTimeout + 5) } else { $null }

    foreach ($d in $dispatchList) {
        $result = $null
        $pipeOk = $pipeResults.ContainsKey($d.wdir)

        if ($pipeOk) {
            $result = $pipeResults[$d.wdir]
        }

        if (-not $result) {
            # File fallback
            $wq = Join-Path (Join-Path $ClusterDir $d.wdir) "queue.txt"
            $cmdData = $dispatchList | Where-Object { $_.cid -eq $d.cid } | Select-Object -First 1
            $fallbackJson = @{v=3;state="pending";cmd_id=$d.cid;command="";type="";timeout=$d.timeout}
            if ($cmdData -and $cmdData.cmdJson) {
                $parsed = $cmdData.cmdJson | ConvertFrom-Json
                $fallbackJson.command = $parsed.c
                $fallbackJson.type = $parsed.t
            }
            WriteF $wq ($fallbackJson | ConvertTo-Json -Compress)
            try { $we=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Wkr_$($d.channel)"); $we.Set(); $we.Dispose() } catch {}
            TLog "[$($d.cid)] file fallback to $($d.channel)"
        } else {
            TLog "[$($d.cid)] pipe OK to $($d.channel) e=$($result.e) o=$(([string]$result.o).Length)chars"
        }

        # V5: Filter CLIXML from stderr before writing result
        if ($result -and $result.s -and $script:reLoaded) {
            $cleanS = Filter-CLIXML $result.s
            if ($cleanS -ne $result.s) { $result.s = $cleanS }
        }
        # Write result file (for async callers that poll)
        if ($result) {
            WriteF (Join-Path $ClusterDir "r_$($d.cid).json") ($result | ConvertTo-Json -Compress)
        }
    }

    # ── Collect file-fallback results ──
    foreach ($d in $dispatchList) {
        if ($d.async) { continue }
        if ($pipeResults.ContainsKey($d.wdir)) { continue }

        $resF = Join-Path (Join-Path $ClusterDir $d.wdir) "r_$($d.cid).json"
        $wr = $null
        while ($fileFallbackDeadline -and (Get-Date) -lt $fileFallbackDeadline) {
            $wr = ReadJ $resF
            if ($wr -and $wr.id -eq $d.cid -and ($wr.state -eq "done" -or $wr.state -eq "error")) { break }
            # Event-driven wait for file fallback
            if ($resultEvent) { $null = $resultEvent.WaitOne(30) } else { Start-Sleep -Milliseconds 30 }
        }
        if ($wr -and $wr.id -eq $d.cid) {
            # V5: Filter CLIXML in file-fallback results
            if ($wr.s -and $script:reLoaded) { $cleanS = Filter-CLIXML $wr.s; if ($cleanS -ne $wr.s) { $wr.s = $cleanS } }
            WriteF (Join-Path $ClusterDir "r_$($d.cid).json") ($wr | ConvertTo-Json -Compress)
            TLog "[$($d.cid)] file result e=$($wr.e) o=$(([string]$wr.o).Length)chars"
        } else {
            WriteF (Join-Path $ClusterDir "r_$($d.cid).json") (@{state="error";id=$d.cid;err="TIMEOUT"} | ConvertTo-Json -Compress)
            TLog "[$($d.cid)] TIMEOUT"
        }
    }

    # ── Signal per-command result events (for pipe server / external waiters) ──
    foreach ($d in $dispatchList) {
        try { $ce=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result_$($d.cid)"); $ce.Set(); $ce.Dispose() } catch {}
    }

    # ── Reset master queue (only if we processed it) ──
    WriteF $masterQueue $idleMaster; $lastQueueContent = $idleMaster

    # ── Prune ──
    if ($processedIds.Count -gt 200) {
        $oldest = $processedIds.Keys | Sort-Object { $processedIds[$_] } | Select-Object -First ($processedIds.Count - 200)
        foreach ($k in $oldest) { $processedIds.Remove($k) }
    }
}
