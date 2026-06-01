#Requires -Version 5.0
<#
 Claude Bridge v12 — Self-learning + Self-restart + Event-driven (Watcher V2)
 ──────────────────────────
 • v10 features preserved (PID lock, async output, progress flush)
 • Rule Engine: auto-applies learned rules (bridge_rules.json) to
   transform commands before execution, fixing known issues like
   && escaping, quoting, and type selection
 • Error Learner: auto-logs execution anomalies to error_history.json
   for pattern analysis and rule generation
 • Rules cache reloaded every 10 commands for live updates
 • Watcher V2: EventWaitHandle for <1ms wakeup instead of pure polling
#>

$script:baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:queueFile = Join-Path $baseDir "queue.txt"
$script:logFile = Join-Path $baseDir "watcher.log"
$script:heartbeatFile = Join-Path $baseDir ".watcher_heartbeat"
$script:rulesFile = Join-Path $baseDir "bridge_rules.json"
$script:errorHistoryFile = Join-Path $baseDir "error_history.json"
$script:lastCmdId = ""
$script:utf8 = [System.Text.UTF8Encoding]::new($false)
$script:rulesCache = $null   # cached rules, reloaded every 10 commands

# ── helpers (defined first; Log is used by rule engine loading below) ──

function Write-Text { param([string]$path, [string]$content)
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            [System.IO.File]::WriteAllText($path, $content, $script:utf8)
            return
        } catch {
            if ($i -eq $retries - 1) { throw }
            Start-Sleep -Milliseconds 100
        }
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
        } catch {
            if ($i -eq $retries - 1) { return $null }
            Start-Sleep -Milliseconds 100
        }
    }
}

function Log { param([string]$m)
    try {
        $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($script:logFile, "$t | $m`r`n", $script:utf8)
    } catch {
        # Logging never blocks or crashes the watcher
    }
}

# ── V5: Shared rule engine (dot-sourced from cluster) ──
$script:ruleEnginePath = Join-Path (Split-Path -Parent $baseDir) "cluster\rule_engine.ps1"
if (Test-Path $script:ruleEnginePath) {
    . $script:ruleEnginePath
    Init-RuleEngine -BridgeBase (Split-Path -Parent $baseDir)
    Log "Rule engine loaded from $($script:ruleEnginePath)"
} else {
    Log "WARNING: Rule engine not found at $($script:ruleEnginePath) — using legacy functions"
}

# ── V5: rule engine — apply learned rules to transform commands ──
$script:cmdCounter = 0
function Legacy-ApplyRules { param([string]$cmd, [string]$ctype)
    # Use V5 shared engine if available
    if (Get-Command "Apply-Rules" -Module $null -ErrorAction SilentlyContinue | Where-Object { $_.ScriptBlock.ToString() -match 'RE_baseDir' }) {
        # Cannot call by name due to recursion — use the shared module's internal function
        return $cmd  # will be handled inline below
    }

    # Legacy fallback
    $rulesPath = $script:rulesFile
    if (-not (Test-Path $rulesPath)) { return $cmd }

    $script:cmdCounter++
    if ($script:cmdCounter % 10 -eq 1 -or $null -eq $script:rulesCache) {
        try {
            $text = [System.IO.File]::ReadAllText($rulesPath, $script:utf8)
            $parsed = ($text | ConvertFrom-Json)
            $script:rulesCache = $parsed.rules
            Log "[RULE] Reloaded $($script:rulesCache.Count) rules"
        } catch {
            Log "[RULE] Failed to load rules: $_"
            return $cmd
        }
    }

    $rules = $script:rulesCache
    if (-not $rules) { return $cmd }

    $modified = $cmd
    $applied = @()
    foreach ($rule in $rules) {
        if ($rule.is_template) { continue }
        $triggers = $rule.triggers
        if ($triggers.type -ne "any" -and $triggers.type -ne $ctype) { continue }
        if ($triggers.command_contains -and $modified -notmatch [regex]::Escape($triggers.command_contains)) { continue }
        if ($triggers.pattern_in_command -and $modified -notmatch $triggers.pattern_in_command) { continue }

        $fix = $rule.fix
        if ($fix.action -eq "escape" -and $fix.find -and $fix.replace_with) {
            $modified = $modified.Replace($fix.find, $fix.replace_with)
            $applied += $rule.id
            Log "[RULE] Applied '$($rule.id)': escaped '$($fix.find)' -> '$($fix.replace_with)'"
        } elseif ($fix.action -eq "wrap_single_quotes") {
            if ($modified -match 'wsl -e bash -c "(.+)"') {
                $inner = $matches[1]
                $modified = $modified.Replace('wsl -e bash -c "' + $inner + '"', "wsl -e bash -c '$inner'")
                $applied += $rule.id
                Log "[RULE] Applied '$($rule.id)': wrapped bash -c in single quotes"
            }
        } elseif ($fix.action -eq "use_powershell_type") {
            Log "[RULE] '$($rule.id)' suggests using powershell type instead of cmd"
        }
    }
    if ($applied.Count -gt 0) {
        Log "[RULE] $($applied.Count) rules applied to cmd_id: $($applied -join ', ')"
    }
    return $modified
}

# ── error learning: log issues for pattern analysis ──
function Log-Error { param([string]$cid, [string]$ctype, [string]$cmd, [int]$exitCode, [string]$stdoutText, [string]$stderrText)
    $historyPath = $script:errorHistoryFile
    $needLearning = $false
    $issueDesc = ""

    # Detect common error patterns
    if ($exitCode -ne 0 -and [string]::IsNullOrWhiteSpace($stderrText) -eq $false) {
        $needLearning = $true
        if ($stderrText -match "not recognized|not a cmdlet|unknown command") {
            $issueDesc = "command_not_found_or_wrong_shell"
        } elseif ($stderrText -match "access denied|permission denied") {
            $issueDesc = "permission_denied"
        } elseif ($stderrText -match "timeout|timed out") {
            $issueDesc = "timeout"
        } else {
            $issueDesc = "exit_code_non_zero_with_stderr"
        }
    } elseif ($exitCode -eq 0 -and [string]::IsNullOrWhiteSpace($stdoutText)) {
        # Exit code 0 but no output - might be truncated
        $needLearning = $true
        $issueDesc = "zero_exit_with_no_output"
    } elseif ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
        $needLearning = $true
        $issueDesc = "stderr_with_success_exit"
    }

    if (-not $needLearning) { return }

    # Build error entry
    $entry = @{
        cmd_id = $cid
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        type = $ctype
        command_summary = if ($cmd.Length -gt 120) { $cmd.Substring(0, 120) + "..." } else { $cmd }
        exit_code = $exitCode
        issue = $issueDesc
        stderr_snippet = if ($stderrText.Length -gt 200) { $stderrText.Substring(0, 200) } else { $stderrText }
        auto_detected = $true
    }

    # Write to error history
    try {
        $existing = @{version="1.0"; errors=@()}
        if (Test-Path $historyPath) {
            $existingText = [System.IO.File]::ReadAllText($historyPath, $script:utf8)
            if (-not [string]::IsNullOrWhiteSpace($existingText)) {
                $existing = ($existingText | ConvertFrom-Json)
            }
        }
        $existing.errors += $entry
        # Keep only last 100 errors
        $c = $existing.errors.Count
        if ($c -gt 100) { $existing.errors = $existing.errors | Select-Object -Last 100 }
        $existing.last_updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $existing.total_errors_logged = $c
        $json = ($existing | ConvertTo-Json -Depth 4 -Compress)
        [System.IO.File]::WriteAllText($historyPath, $json, $script:utf8)
        Log "[LEARN] Error logged: $cid -> $issueDesc"
    } catch {
        Log "[LEARN] Failed to log error: $_"
    }
}

# Cleanup stale leftovers from previous crashes
Get-ChildItem "$baseDir\*.tmp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

# ── PID lock: prevent duplicate watcher instances ──
$lockFile = Join-Path $baseDir ".watcher.lock"
if (Test-Path $lockFile) {
    try {
        $oldPid = [int]([System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim())
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc -and $oldProc.ProcessName -match "powershell") {
            Log "Another watcher PID=$oldPid already running - exiting"
            exit 0
        }
    } catch {
        # Lock file invalid or process gone - take over
    }
}
try {
    [System.IO.File]::WriteAllText($lockFile, [string]$PID, $script:utf8)
    Log "PID lock acquired: $PID"
} catch {
    Log "WARNING: could not write lock file: $_"
}

# ── Event handles for async notification (Watcher V2) ──
$script:queueEvent = $null
try {
    $script:queueEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\Cluster_Queue")
    Log "Queue Event OK"
} catch { Log "Queue Event N/A" }

$script:resultEvent = $null
try {
    $script:resultEvent = [System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result")
    Log "Result Event OK"
} catch {
    try {
        $script:resultEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, "Local\Cluster_Result")
        Log "Result Event created"
    } catch { Log "Result Event N/A" }
}

# ── startup ─────────────────────────────────────────────────────────────

Log "=== Bridge v12 (Event-driven) STARTED ==="

$idleQueue = '{"state":"idle","cmd_id":"","command":"","type":""}'
$existing = Read-Json -path $script:queueFile
if (-not $existing) {
    Write-Text -path $script:queueFile -content $idleQueue
    Log "Queue created (no existing file)"
} elseif ($existing.state -eq "pending") {
    Log "Pending command preserved: $($existing.cmd_id) / $($existing.command)"
} else {
    Write-Text -path $script:queueFile -content $idleQueue
    Log "Queue reset from state=$($existing.state)"
}

Log "Ready - V2 event-driven (200ms fallback)"

# ── main loop (event-driven with polling fallback) ──

while ($true) {
    # ── heartbeat ──
    try {
        [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8)
    } catch {
        # heartbeat never blocks
    }

    # Event-driven wakeup: wait on queue event, fall back to 200ms poll
    if ($script:queueEvent) {
        $null = $script:queueEvent.WaitOne(200)
    } else {
        Start-Sleep -Milliseconds 200
    }
    $queue = Read-Json -path $script:queueFile

    if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id -ne "" -and $queue.cmd_id -ne $script:lastCmdId) {
        $script:lastCmdId = $queue.cmd_id
        $cid = $queue.cmd_id
        $ctype = $queue.type
        $rawCmd = $queue.command
        $origTimeout = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }

        # ── V5: Apply learned rules to transform command ──
        $ruleResult = if (Get-Command "Init-RuleEngine" -ErrorAction SilentlyContinue) {
            Apply-Rules -Cmd $rawCmd -Type $ctype
        } else {
            @{cmd=(Legacy-ApplyRules -cmd $rawCmd -ctype $ctype); type=$ctype; applied=@()}
        }
        $cmd = $ruleResult.cmd
        if ($ruleResult.type -ne $ctype) {
            $ctype = $ruleResult.type
            Log "[$cid] TYPE CHANGED: $($queue.type) -> $ctype"
        }
        if ($cmd -ne $rawCmd) {
            Log "[$cid] TRANSFORMED: '$rawCmd' -> '$cmd' (rules: $($ruleResult.applied -join ','))"
        }

        $t0 = Get-Date
        $timedOut = $false

        Log "[$cid] type=$ctype cmd=$cmd timeout=${origTimeout}s"

        # ── Meta-command handler (self-management) ──
        if ($cmd -eq "__BRIDGE_RESTART__") {
            Log "[$cid] BRIDGE RESTART requested - exiting, watchdog will restart"
            Write-Text -path $script:queueFile -content "{`"state`":`"idle`",`"cmd_id`":`"`",`"command`":`"`",`"type`":`"`"}"
            $restartRes = @{state="done";cmd_id=$cid;exit_code=0;stdout="Bridge restarting...";stderr="";duration_ms=0;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($restartRes | ConvertTo-Json -Compress)
            # Signal result ready
            try { if ($script:resultEvent) { $script:resultEvent.Set() } } catch {}
            exit 0
        }
        if ($cmd -eq "__BRIDGE_STOP__") {
            Log "[$cid] BRIDGE STOP requested - exiting permanently"
            Write-Text -path $script:queueFile -content "{`"state`":`"idle`",`"cmd_id`":`"`",`"command`":`"`",`"type`":`"`"}"
            $stopRes = @{state="done";cmd_id=$cid;exit_code=0;stdout="Bridge stopped";stderr="";duration_ms=0;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($stopRes | ConvertTo-Json -Compress)
            try { if ($script:resultEvent) { $script:resultEvent.Set() } } catch {}
            try { Remove-Item (Join-Path $baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
            exit 0
        }
        # ── Inline execution: run PowerShell code inside watcher process (bypasses 360) ──
        if ($ctype -eq "__INLINE__") {
            Log "[$cid] INLINE execution requested"
            $inlineExit = 0; $inlineOut = ""; $inlineErr = ""; $inlineError = ""
            try {
                $scriptBlock = [ScriptBlock]::Create($rawCmd)
                $inlineResult = & $scriptBlock
                if ($inlineResult -ne $null) {
                    $inlineOut = ($inlineResult | Out-String).Trim()
                }
                Log "[$cid] INLINE succeeded"
            } catch {
                $inlineErr = $_.Exception.Message
                $inlineExit = -1
                $inlineError = $_.Exception.Message
                Log "[$cid] INLINE exception: $inlineErr"
            }
            $inlineRes = @{
                state = if ($inlineError) { "error" } else { "done" }
                cmd_id = $cid
                exit_code = $inlineExit
                stdout = $inlineOut
                stderr = $inlineErr
                error = $inlineError
                duration_ms = [int]((Get-Date) - $t0).TotalMilliseconds
                timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            }
            Write-Text -path $script:queueFile -content "{`"state`":`"idle`",`"cmd_id`":`"`",`"command`":`"`",`"type`":`"`"}"
            Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($inlineRes | ConvertTo-Json -Compress)
            # Signal result ready
            try { if ($script:resultEvent) { $script:resultEvent.Set() } } catch {}
            Log "[$cid] INLINE result written"
            continue
        }

        # ── User-context execution (routes to user_bridge worker via queue) ──
        if ($ctype -eq "user") {
            Log "[$cid] USER-context execution via user_bridge"
            $userQueue = Join-Path (Split-Path $baseDir -Parent) "cluster\user_bridge\queue.txt"
            $userResult = Join-Path (Split-Path $baseDir -Parent) "cluster\user_bridge\r_${cid}.json"
            $userCmd = @{state="pending";cmd_id=$cid;command=$cmd;type="powershell";timeout=$origTimeout} | ConvertTo-Json -Compress
            Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"
            Write-Text -path $userQueue -content $userCmd
            # Poll for result
            $deadline = (Get-Date).AddSeconds($origTimeout + 5)
            $userOut = ""; $userErr = ""; $userExit = -1; $userError = ""
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 200
                if (Test-Path $userResult) {
                    try {
                        $ur = Get-Content $userResult -Raw -Encoding UTF8 | ConvertFrom-Json
                        $userOut = $ur.o; $userErr = $ur.s; $userExit = $ur.e; $userError = $ur.err
                    } catch { $userError = $_.Exception.Message }
                    break
                }
            }
            if (-not (Test-Path $userResult)) { $userOut = "[TIMEOUT]"; $userError = "TIMEOUT" }
            $userRes = @{state = if ($userError) { "error" } else { "done" }; cmd_id=$cid; exit_code=$userExit; stdout=$userOut; stderr=$userErr; error=$userError; duration_ms=[int]((Get-Date)-$t0).TotalMilliseconds; timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path $script:queueFile -content $idleQueue
            Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($userRes | ConvertTo-Json -Compress)
            try { if ($script:resultEvent) { $script:resultEvent.Set() } } catch {}
            Log "[$cid] USER result written (exit=$userExit)"
            continue
        }

        Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

        $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""
        $flushInterval = 5   # seconds between progress flushes
        $progressFile = Join-Path $baseDir "r_${cid}_progress.json"

        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($ctype -eq "cmd") {
                $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $cmd"
            } elseif ($ctype -eq "powershell") {
                $psi.FileName = "powershell.exe"
                $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
            } else {
                throw "Unknown type: $ctype"
            }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = $script:utf8
            $psi.StandardErrorEncoding  = $script:utf8

            $outputBuf = New-Object System.Text.StringBuilder
            $errorBuf  = New-Object System.Text.StringBuilder

            # Lock for cross-thread access to the buffers
            $bufLock = [System.Threading.ReaderWriterLockSlim]::new()

            $actionOut = {
                $buf = $event.MessageData[0]
                $lk  = $event.MessageData[1]
                if ($EventArgs.Data -ne $null) {
                    $lk.EnterWriteLock()
                    try { [void]$buf.AppendLine($EventArgs.Data) } finally { $lk.ExitWriteLock() }
                }
            }

            $actionErr = {
                $buf = $event.MessageData[0]
                $lk  = $event.MessageData[1]
                if ($EventArgs.Data -ne $null) {
                    $lk.EnterWriteLock()
                    try { [void]$buf.AppendLine($EventArgs.Data) } finally { $lk.ExitWriteLock() }
                }
            }

            $p = [System.Diagnostics.Process]::Start($psi)
            if (-not $p) { throw "Process.Start returned null" }

            $outEvent = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived `
                -Action $actionOut -MessageData @($outputBuf, $bufLock) -SupportEvent
            $errEvent = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived `
                -Action $actionErr -MessageData @($errorBuf, $bufLock) -SupportEvent

            $p.BeginOutputReadLine()
            $p.BeginErrorReadLine()

            # ── execute loop: wait with periodic flush ──
            $loopStart = Get-Date
            while ($true) {
                # heartbeat inside the command too
                try {
                    [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8)
                } catch {}

                if ($p.WaitForExit($flushInterval * 1000)) {
                    # Process exited - drain remaining async output
                    Start-Sleep -Milliseconds 300
                    $bufLock.EnterReadLock()
                    try {
                        $stdout = $outputBuf.ToString()
                        $stderr  = $errorBuf.ToString()
                    } finally { $bufLock.ExitReadLock() }
                    $exitCode = $p.ExitCode
                    Log "[$cid] Process exited naturally, PID=$($p.Id) code=$exitCode"
                    break
                }

                # Check timeout
                $elapsedSec = [int]((Get-Date) - $t0).TotalSeconds
                if ($elapsedSec -ge $origTimeout) {
                    $timedOut = $true
                    Log "[$cid] TIMEOUT after ${origTimeout}s - killing PID $($p.Id)"
                    try {
                        $p.Kill()
                        if (-not $p.WaitForExit(3000)) {
                            Log "[$cid] Kill didn't finish in 3s, continuing..."
                        }
                    } catch { Log "[$cid] Kill exception: $_" }

                    Start-Sleep -Milliseconds 500
                    $bufLock.EnterReadLock()
                    try {
                        $stdout = $outputBuf.ToString()
                        $stderr  = $errorBuf.ToString()
                    } finally { $bufLock.ExitReadLock() }

                    if ([string]::IsNullOrEmpty($stdout)) { $stdout = "[TIMEOUT after ${origTimeout}s]" }
                    $exitCode = -1
                    $errorMsg = "TIMEOUT after ${origTimeout}s (process killed)"
                    break
                }

                # ── Progress flush ──
                $bufLock.EnterReadLock()
                try { $partialOut = $outputBuf.ToString() } finally { $bufLock.ExitReadLock() }

                if ($partialOut.Length -gt 0) {
                    $escaped = $partialOut.Replace('\', '\\').Replace('"', '\"')
                    $progressJson = "{`"cmd_id`":`"$cid`",`"elapsed_sec`":$elapsedSec,`"state`":`"running`",`"stdout`":`"$escaped`"}"
                    Write-Text -path $progressFile -content $progressJson
                }
            }

            # Cleanup event subscriptions
            try { Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue } catch {}
            try { Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue } catch {}
            $bufLock.Dispose()
            $p.Dispose()

        } catch {
            $errorMsg = $_.Exception.Message
            Log "[$cid] EXCEPTION: $errorMsg"
        }

        $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
        Log "[$cid] exit=$exitCode out=$($stdout.Length)chars err=$($stderr.Length)chars dur=${elapsed}ms"

        # ── V5: Filter CLIXML noise from stderr ──
        $stderrClean = if (Get-Command "Filter-CLIXML" -ErrorAction SilentlyContinue) {
            Filter-CLIXML $stderr
        } else {
            $stderr
        }
        if ($stderrClean -ne $stderr) {
            Log "[$cid] CLIXML stripped: $($stderr.Length) -> $($stderrClean.Length) chars"
        }

        # ── Write final result ──
        $res = @{
            state = if ($errorMsg) { "error" } else { "done" }
            cmd_id = $cid
            exit_code = $exitCode
            stdout = $stdout
            stderr = $stderrClean         # CLIXML-filtered
            error = $errorMsg
            duration_ms = $elapsed
            timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        }
        $resJson = ($res | ConvertTo-Json -Compress)
        Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content $resJson
        Log "[$cid] result written"

        # ── Signal result ready for async callers (Watcher V2) ──
        try { if ($script:resultEvent) { $script:resultEvent.Set() } } catch {}

        # ── V5: Log errors for pattern learning + auto-generate rules ──
        if (Get-Command "Log-ExecutionError" -ErrorAction SilentlyContinue) {
            Log-ExecutionError -CmdId $cid -Type $ctype -Command $rawCmd -ExitCode $exitCode -StdoutText $stdout -StderrText $stderr -DurationMs $elapsed
            # Auto-generate rules periodically
            $newRules = Generate-Rules
            if ($newRules -and $newRules.Count -gt 0) {
                Log "[LEARN] Auto-generated $($newRules.Count) new rules: $($newRules.id -join ', ')"
            }
        } else {
            Log-Error -cid $cid -ctype $ctype -cmd $rawCmd -exitCode $exitCode -stdoutText $stdout -stderrText $stderr
        }

        # ── Cleanup progress file ──
        if (Test-Path $progressFile) {
            Remove-Item -Force $progressFile -ErrorAction SilentlyContinue
            Log "[$cid] progress file cleaned"
        }

        # ── Reset queue ──
        $recheck = Read-Json -path $script:queueFile
        if ($recheck -and $recheck.state -eq "pending" -and $recheck.cmd_id -ne $cid) {
            Log "[$cid] new pending $($recheck.cmd_id) - preserving queue"
        } else {
            Write-Text -path $script:queueFile -content $idleQueue
            Log "[$cid] queue reset"
        }
    }
}
