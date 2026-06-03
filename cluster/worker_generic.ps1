#Requires -Version 5.0
<#
 worker_generic.ps1 — Generic parallel worker (V3 — PIPE-DIRECT)
 ─────────────────
 V3 (2026-06-04): Pipe server executes commands DIRECTLY and returns results
   through the pipe — no queue file I/O in fast path. Result also written to
   r_{cid}.json for backward compatibility. FSW + queue file is fallback only.

 V2 (2026-06-03): FileSystemWatcher replaces 200ms polling for zero-latency
   queue detection. ~22ms saved per command.

 V1 (2026-06-03): Initial — pool-friendly worker with own Named Pipe server,
   queue file, ScriptBlock fast path + subprocess fallback.

 Usage: powershell -File worker_generic.ps1 -WorkerId g1 [-BridgeBase D:\...]
        WorkerId becomes pipe name: Cluster_Wkr_generic_g1
#>

param(
    [string]$WorkerId = $(throw "WorkerId required (e.g. g1, g2, g3)"),
    [string]$BridgeBase = ""
)

if (-not $BridgeBase) {
    $BridgeBase = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$workerName = "wkr_${WorkerId}"
$script:pipeName = "Cluster_Wkr_generic_${WorkerId}"

$script:baseDir = Join-Path $BridgeBase "cluster\worker_generic_${WorkerId}"
$script:queueFile = Join-Path $script:baseDir "queue.txt"
$script:logFile = Join-Path $script:baseDir "watcher.log"
$script:heartbeatFile = Join-Path $script:baseDir ".heartbeat"
$script:resultDir = Join-Path $BridgeBase "watcher"

$script:utf8 = [System.Text.UTF8Encoding]::new($false)
$script:utf8nobom = [System.Text.UTF8Encoding]::new($false)

New-Item -Path $script:baseDir -ItemType Directory -Force | Out-Null
New-Item -Path $script:resultDir -ItemType Directory -Force | Out-Null

# ── Utilities ──
function WF($p,$c) { for ($i=0;$i -lt 3;$i++){try{[System.IO.File]::WriteAllText($p,$c,$script:utf8nobom);return}catch{if($i -eq 2){throw};Start-Sleep -Milliseconds 20}}}
function RJ($p) { if(-not(Test-Path $p)){return $null};for($i=0;$i -lt 3;$i++){try{$t=[System.IO.File]::ReadAllText($p,$script:utf8nobom);if([string]::IsNullOrWhiteSpace($t)){return $null};return($t|ConvertFrom-Json)}catch{if($i -eq 2){return $null};Start-Sleep -Milliseconds 20}}}
function Log($m) { try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($script:logFile, "$t | [$workerName] $m`r`n", $script:utf8nobom) } catch {} }

# ── PID lock ──
$lockFile = Join-Path $script:baseDir ".lock"
if (Test-Path $lockFile) {
    try {
        $oldPid = [int]([System.IO.File]::ReadAllText($lockFile, $script:utf8nobom).Trim())
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc) { Log "Stale PID=$oldPid still running — exiting"; exit 0 }
    } catch {}
}
WF $lockFile ([string]$PID)

# ═══════════════════════════════════════════════════════════════
# V3: PIPE-DIRECT SERVER — executes commands and returns results
# through the pipe. No queue file intermediary in the fast path.
# ═══════════════════════════════════════════════════════════════

$idleQueue = '{"state":"idle","cmd_id":"","command":"","type":""}'
$pipeRunning = $true
$pipePs = [PowerShell]::Create()
$null = $pipePs.AddScript({
    param($pn, $qf, $logF, $resultD, $baseD)
    $u8 = [System.Text.UTF8Encoding]::new($false)
    function W($m) { try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($logF,"$t | [PIPE] $m`r`n",$u8) } catch {} }
    function WF($p,$c) { for ($i=0;$i -lt 3;$i++){try{[System.IO.File]::WriteAllText($p,$c,$u8);return}catch{if($i -eq 2){throw};Start-Sleep -Milliseconds 20}}}
    function RJ($p) { if(-not(Test-Path $p)){return $null};for($i=0;$i -lt 3;$i++){try{$t=[System.IO.File]::ReadAllText($p,$u8);if([string]::IsNullOrWhiteSpace($t)){return $null};return($t|ConvertFrom-Json)}catch{if($i -eq 2){return $null};Start-Sleep -Milliseconds 20}}}

    W "V3 PIPE-DIRECT server starting: $pn"

    while ($true) {
        try {
            $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
                $pn,
                [System.IO.Pipes.PipeDirection]::InOut,
                1,
                [System.IO.Pipes.PipeTransmissionMode]::Message
            )
            $pipe.WaitForConnection()
            $reader = New-Object System.IO.StreamReader($pipe, $u8)
            $writer = New-Object System.IO.StreamWriter($pipe, $u8)
            $writer.AutoFlush = $true

            $cmdJson = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($cmdJson)) {
                $writer.WriteLine('{"status":"error","error":"empty command"}')
                $pipe.Close()
                continue
            }

            # Parse command
            try { $cmdObj = $cmdJson | ConvertFrom-Json } catch {
                W "Failed to parse JSON: $_"
                $writer.WriteLine('{"status":"error","error":"invalid JSON"}')
                $pipe.Close()
                continue
            }

            $cid = $cmdObj.cmd_id
            $ctype = $cmdObj.type
            $rawCmd = $cmdObj.command
            $timeout = if ($cmdObj.timeout -gt 0) { $cmdObj.timeout } else { 30 }
            $t0 = Get-Date

            W "[$cid] PIPE-DIRECT type=$ctype timeout=${timeout}s"

            # Mark queue as running (for external observers)
            WF $qf "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

            $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""
            $fastPath = $false

            # ── V3 ScriptBlock fast path (in runspace, with timeout) ──
            if ($ctype -eq "powershell" -or $ctype -eq "powershell_text" -or $ctype -eq "inline") {
                try {
                    $sbCmd = $rawCmd -replace '\bexit\s+\d+\s*;?\s*$', '' -replace '\bexit\s*;?\s*$', ''
                    $ps = [PowerShell]::Create()
                    $ps.AddScript({ param($c) & ([ScriptBlock]::Create($c)) 2>&1 }).AddArgument($sbCmd)
                    $h = $ps.BeginInvoke()
                    $tMs = [Math]::Max(1000, ($timeout * 1000))
                    if ($h.AsyncWaitHandle.WaitOne($tMs)) {
                        $r = $ps.EndInvoke($h)
                        $stdout = if ($r) { ($r | Out-String).Trim() } else { "" }
                        $exitCode = 0; $fastPath = $true
                    } else {
                        $ps.Stop()
                        $errorMsg = "TIMEOUT after ${timeout}s"
                        $stdout = "[TIMEOUT]"
                    }
                    $ps.Dispose()
                } catch {
                    W "[$cid] ScriptBlock failed ($($_.Exception.Message)) — subprocess fallback"
                }
            }

            # ── Subprocess fallback ──
            if (-not $fastPath -and -not $errorMsg) {
                try {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    if ($ctype -eq "cmd") {
                        $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $rawCmd"
                    } elseif ($ctype -eq "wsl") {
                        $psi.FileName = "wsl.exe"
                        $psi.Arguments = "-e bash -c `"$($rawCmd -replace '"', '\"')`""
                    } else {
                        $psi.FileName = "powershell.exe"
                        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($rawCmd -replace '"', '\"')`""
                    }
                    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
                    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                    $psi.StandardOutputEncoding = $u8; $psi.StandardErrorEncoding = $u8

                    $p = [System.Diagnostics.Process]::Start($psi)
                    if (-not $p) { throw "Process.Start returned null" }

                    $outTask = $p.StandardOutput.ReadToEndAsync()
                    $errTask = $p.StandardError.ReadToEndAsync()

                    if ($p.WaitForExit(($timeout+2)*1000)) {
                        $exitCode = $p.ExitCode
                        $stdout = $outTask.Result
                        $stderr = $errTask.Result
                    } else {
                        $p.Kill(); Start-Sleep -Milliseconds 300
                        try { $stdout = $outTask.Result } catch { $stdout = "[TIMEOUT]" }
                        try { $stderr = $errTask.Result } catch {}
                        $exitCode = -1; $errorMsg = "TIMEOUT after ${timeout}s"
                    }
                    $p.Dispose()
                } catch {
                    $errorMsg = $_.Exception.Message
                    W "[$cid] EXCEPTION: $errorMsg"
                }
            }

            $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds

            # Build result
            $res = @{
                state = $(if($errorMsg){"error"}else{"done"})
                cmd_id = $cid
                exit_code = $exitCode
                stdout = $stdout
                stderr = $stderr
                error = $errorMsg
                duration_ms = $elapsed
                fast_path = $fastPath
                pipe_direct = $true
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            }

            # Write result to file (backward compatibility)
            $resPath = Join-Path $resultD "r_${cid}.json"
            WF $resPath ($res | ConvertTo-Json -Compress)

            # Return result through pipe
            $pipeResult = @{
                status = $res.state
                cmd_id = $cid
                exit_code = $exitCode
                stdout = $stdout
                stderr = $stderr
                error = $errorMsg
                duration_ms = $elapsed
                fast_path = $fastPath
                pipe_direct = $true
            }
            $pipeJson = $pipeResult | ConvertTo-Json -Compress
            $writer.WriteLine($pipeJson)

            # Reset queue to idle
            WF $qf '{"state":"idle","cmd_id":"","command":"","type":""}'

            W "[$cid] PIPE-DIRECT DONE: exit=$exitCode dur=${elapsed}ms fast=$fastPath"
            $pipe.Close()

        } catch {
            W "Pipe server error: $_"
            Start-Sleep -Milliseconds 200
            try { if ($pipe) { $pipe.Close() } } catch {}
        }
    }
}).AddArgument($script:pipeName).AddArgument($script:queueFile).AddArgument($script:logFile).AddArgument($script:resultDir).AddArgument($script:baseDir)

$pipeHandle = $pipePs.BeginInvoke()
Log "V3 PIPE-DIRECT server started: $script:pipeName"

# ── Initialize queue file ──
$existing = RJ $script:queueFile
if (-not $existing -or $existing.state -eq "idle") {
    WF $script:queueFile $idleQueue
} else {
    Log "Resuming: $($existing.cmd_id)"
}

# ── FileSystemWatcher (fallback — for commands that arrive via queue file) ──
$script:fsw = New-Object System.IO.FileSystemWatcher
$script:fsw.Path = $script:baseDir
$script:fsw.Filter = "queue.txt"
$script:fsw.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
Log "FSW initialized — fallback mode (event-driven, no polling)"

Log "=== $workerName V3 PIPE-DIRECT STARTED (pid=$PID) ==="

# ═══════════════════════════════════════
# Main loop: heartbeat + FSW fallback
# (Pipe server handles primary execution)
# ═══════════════════════════════════════

while ($true) {
    # Heartbeat
    try { WF $script:heartbeatFile (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff") } catch {}

    # FSW: blocks until queue.txt changed OR 500ms heartbeat timeout
    # (longer timeout since pipe is primary path)
    try { $script:fsw.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 500) | Out-Null } catch { Start-Sleep -Milliseconds 500 }

    # Check if a command arrived via queue file (fallback path)
    $queue = RJ $script:queueFile
    if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id) {
        $cid = $queue.cmd_id
        $ctype = $queue.type
        $cmd = $queue.command
        $timeout = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }
        $t0 = Get-Date

        Log "[$cid] FALLBACK-QUEUE type=$ctype timeout=${timeout}s — pipe may have missed this"
        WF $script:queueFile "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

        $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""
        $fastPath = $false

        # ── ScriptBlock fast path ──
        if ($ctype -eq "powershell" -or $ctype -eq "powershell_text" -or $ctype -eq "inline") {
            try {
                $sbCmd = $cmd -replace '\bexit\s+\d+\s*;?\s*$', '' -replace '\bexit\s*;?\s*$', ''
                $ps = [PowerShell]::Create()
                $ps.AddScript({ param($c) & ([ScriptBlock]::Create($c)) 2>&1 }).AddArgument($sbCmd)
                $h = $ps.BeginInvoke()
                $tMs = [Math]::Max(1000, ($timeout * 1000))
                if ($h.AsyncWaitHandle.WaitOne($tMs)) {
                    $r = $ps.EndInvoke($h)
                    $stdout = if ($r) { ($r | Out-String).Trim() } else { "" }
                    $exitCode = 0; $fastPath = $true
                } else {
                    $ps.Stop(); $errorMsg = "TIMEOUT after ${timeout}s"
                    $stdout = "[TIMEOUT]"
                }
                $ps.Dispose()
                if ($fastPath) {
                    $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
                    $res = @{state="done";cmd_id=$cid;exit_code=$exitCode;stdout=$stdout;stderr="";error="";duration_ms=$elapsed;fast_path=$true;pipe_direct=$false;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
                    WF (Join-Path $script:resultDir "r_${cid}.json") ($res | ConvertTo-Json -Compress)
                    Log "[$cid] FALLBACK DONE fast-path: ${elapsed}ms"
                    WF $script:queueFile $idleQueue
                    continue
                }
            } catch {
                Log "[$cid] FALLBACK ScriptBlock failed ($($_.Exception.Message)) — subprocess fallback"
            }
        }

        # ── Subprocess fallback ──
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($ctype -eq "cmd") {
                $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $cmd"
            } elseif ($ctype -eq "wsl") {
                $psi.FileName = "wsl.exe"; $psi.Arguments = "-e bash -c `"$($cmd -replace '"', '\"')`""
            } else {
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($cmd -replace '"', '\"')`""
            }
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = $script:utf8nobom; $psi.StandardErrorEncoding = $script:utf8nobom

            $p = [System.Diagnostics.Process]::Start($psi)
            if (-not $p) { throw "Process.Start returned null" }

            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()

            if ($p.WaitForExit(($timeout+2)*1000)) {
                $exitCode = $p.ExitCode
                $stdout = $outTask.Result
                $stderr = $errTask.Result
            } else {
                $p.Kill(); Start-Sleep -Milliseconds 300
                try { $stdout = $outTask.Result } catch { $stdout = "[TIMEOUT]" }
                try { $stderr = $errTask.Result } catch {}
                $exitCode = -1; $errorMsg = "TIMEOUT after ${timeout}s"
            }
            $p.Dispose()
        } catch {
            $errorMsg = $_.Exception.Message
            Log "[$cid] FALLBACK EXCEPTION: $errorMsg"
        }

        $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
        $res = @{state=$(if($errorMsg){"error"}else{"done"});cmd_id=$cid;exit_code=$exitCode;stdout=$stdout;stderr=$stderr;error=$errorMsg;duration_ms=$elapsed;fast_path=$fastPath;pipe_direct=$false;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
        WF (Join-Path $script:resultDir "r_${cid}.json") ($res | ConvertTo-Json -Compress)
        Log "[$cid] FALLBACK DONE: exit=$exitCode dur=${elapsed}ms fast=$fastPath"
        WF $script:queueFile $idleQueue
    }
}
