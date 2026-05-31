#Requires -Version 5.0
<#
 Claude Bridge Cluster Worker — v1
 ──────────────────────────
 Specialized watcher for a single domain (file/registry/process/network/system/wsl)
 Manages its own queue, PID lock, log, and heartbeat.
#>

param(
    [string]$WorkerName = $(throw "WorkerName required"),
    [string]$BridgeBase = $(throw "BridgeBase required")
)

$script:baseDir = Join-Path $BridgeBase "cluster\\${WorkerName}_bridge"
$script:queueFile = Join-Path $script:baseDir "queue.txt"
$script:logFile = Join-Path $script:baseDir "watcher.log"
$script:heartbeatFile = Join-Path $script:baseDir ".watcher_heartbeat"
$script:lastCmdId = ""
$script:utf8 = [System.Text.UTF8Encoding]::new($false)

# Ensure directory exists
New-Item -Path $script:baseDir -ItemType Directory -Force | Out-Null

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
        [System.IO.File]::AppendAllText($script:logFile, "$t | [$WorkerName] $m`r`n", $script:utf8)
    } catch {}
}

# ── PID lock ──
$lockFile = Join-Path $script:baseDir ".watcher.lock"
if (Test-Path $lockFile) {
    try {
        $oldPid = [int]([System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim())
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc -and $oldProc.ProcessName -match "powershell") {
            Log "Another $WorkerName worker PID=$oldPid already running — exiting"
            exit 0
        }
    } catch {}
}
try { [System.IO.File]::WriteAllText($lockFile, [string]$PID, $script:utf8); Log "PID lock acquired: $PID" }
catch { Log "WARNING: could not write lock file: $_" }

# ── startup ──
Log "=== $WorkerName Bridge Worker STARTED ==="
$idleQueue = '{"state":"idle","cmd_id":"","command":"","type":""}'
$existing = Read-Json -path $script:queueFile
if (-not $existing) { Write-Text -path $script:queueFile -content $idleQueue; Log "Queue created" }
elseif ($existing.state -eq "pending") { Log "Pending command: $($existing.cmd_id)" }
else { Write-Text -path $script:queueFile -content $idleQueue; Log "Queue reset" }

Log "Ready — polling 200ms"

# ── main loop ──
while ($true) {
    # Heartbeat
    try { [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8) } catch {}

    Start-Sleep -Milliseconds 200
    $queue = Read-Json -path $script:queueFile

    if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id -ne "" -and $queue.cmd_id -ne $script:lastCmdId) {
        $script:lastCmdId = $queue.cmd_id
        $cid = $queue.cmd_id
        $ctype = $queue.type
        $rawCmd = $queue.command
        $origTimeout = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }
        $t0 = Get-Date

        Log "[$cid] type=$ctype cmd=$rawCmd timeout=${origTimeout}s"

        # ── Inline execution ──
        if ($ctype -eq "__INLINE__") {
            Log "[$cid] INLINE execution"
            $inlineExit = 0; $inlineOut = ""; $inlineErr = ""; $inlineError = ""
            try {
                $scriptBlock = [ScriptBlock]::Create($rawCmd)
                $inlineResult = & $scriptBlock
                if ($inlineResult -ne $null) { $inlineOut = ($inlineResult | Out-String).Trim() }
                Log "[$cid] INLINE succeeded"
            } catch {
                $inlineErr = $_.Exception.Message; $inlineExit = -1; $inlineError = $_.Exception.Message
                Log "[$cid] INLINE exception: $inlineErr"
            }
            Write-Text -path $script:queueFile -content $idleQueue
            $inlineRes = @{state=$(if($inlineError){"error"}else{"done"});cmd_id=$cid;exit_code=$inlineExit;stdout=$inlineOut;stderr=$inlineErr;error=$inlineError;duration_ms=[int]((Get-Date)-$t0).TotalMilliseconds;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $script:baseDir "r_${cid}.json") -content ($inlineRes | ConvertTo-Json -Compress)
            Log "[$cid] INLINE result written"
            continue
        }

        Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

        $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($ctype -eq "cmd") {
                $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $rawCmd"
            } elseif ($ctype -eq "powershell") {
                $psi.FileName = "powershell.exe"
                $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($rawCmd))
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
            } elseif ($ctype -eq "wsl") {
                $psi.FileName = "wsl.exe"
                $psi.Arguments = "-e bash -c $rawCmd"
            } else {
                throw "Unknown type: $ctype"
            }
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = $script:utf8; $psi.StandardErrorEncoding = $script:utf8

            $outputBuf = New-Object System.Text.StringBuilder; $errorBuf = New-Object System.Text.StringBuilder
            $p = [System.Diagnostics.Process]::Start($psi)
            if (-not $p) { throw "Process.Start returned null" }

            $outEvent = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -Action { $d=$event.MessageData; $lk=$event.MessageData[1];if($EventArgs.Data-ne$null){$lk.EnterWriteLock();try{[void]$d[0].AppendLine($EventArgs.Data)}finally{$lk.ExitWriteLock()}}} -MessageData @($outputBuf, $null) -SupportEvent
            $errEvent = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -Action { $d=$event.MessageData; $lk=$event.MessageData[1];if($EventArgs.Data-ne$null){$lk.EnterWriteLock();try{[void]$d[0].AppendLine($EventArgs.Data)}finally{$lk.ExitWriteLock()}}} -MessageData @($errorBuf, $null) -SupportEvent
            $p.BeginOutputReadLine(); $p.BeginErrorReadLine()

            if ($p.WaitForExit(($origTimeout+2) * 1000)) {
                Start-Sleep -Milliseconds 300
                $stdout = $outputBuf.ToString(); $stderr = $errorBuf.ToString(); $exitCode = $p.ExitCode
                Log "[$cid] exit=$exitCode out=$($stdout.Length)chars err=$($stderr.Length)chars"
            } else {
                $p.Kill(); $stdout = "[TIMEOUT]"; $exitCode = -1; $errorMsg = "TIMEOUT"
                Log "[$cid] TIMEOUT"
            }
            try { Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue } catch {}
            try { Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue } catch {}
            $p.Dispose()
        } catch {
            $errorMsg = $_.Exception.Message; Log "[$cid] EXCEPTION: $errorMsg"
        }

        $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
        $res = @{state=$(if($errorMsg){"error"}else{"done"});cmd_id=$cid;exit_code=$exitCode;stdout=$stdout;stderr=$stderr;error=$errorMsg;duration_ms=$elapsed;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
        Write-Text -path (Join-Path $script:baseDir "r_${cid}.json") -content ($res | ConvertTo-Json -Compress)
        Log "[$cid] result written"

        $recheck = Read-Json -path $script:queueFile
        if ($recheck -and $recheck.state -eq "pending" -and $recheck.cmd_id -ne $cid) {
            Log "[$cid] preserving new pending $($recheck.cmd_id)"
        } else {
            Write-Text -path $script:queueFile -content $idleQueue
            Log "[$cid] queue reset"
        }
    }
}
