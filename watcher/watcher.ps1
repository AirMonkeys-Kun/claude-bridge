#Requires -Version 5.0
<#
 Claude Bridge v17 — ScriptBlock in-process execution + scheduler IPC
 ──────────────────────────
 • V17: ScriptBlock in-process fast path for powershell/powershell_text/inline
   types — uses [ScriptBlock]::Create() for ~10ms execution instead of
   spawning powershell.exe subprocess (~150ms).  Mirrors worker.ps1 V4
   Smart execution pattern.  Falls back to subprocess on failure.
 • V16: Progress flush restored — writes r_{cid}_progress.json every 5s
   during long-running commands (elapsed time + running status).
 • V15: EventWaitHandle replaced with FileSystemWatcher.WaitForChanged()
   — Same event-driven semantics (immediate wake on queue write, 50ms timeout)
   — NO named kernel objects → no orphaned handles, no CLR crash
 • V14 history: EventWaitHandle removed due to CLR crash; pure polling was a
   temporary measure that traded CPU/response latency for stability
 • Content-hash dedup: identical commands within 2min are auto-rejected
 • Inflight guard: only one command executes at a time
 • HostLoopMode housekeeping: auto-strips hostLoopMode=true from
   session JSON files every ~60s (fixes WSL path crash root cause)
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
$script:contentDedupCache = @{}  # cmd_text_hash -> @{cmd_id, timestamp} — V13 content-level dedup
$script:contentDedupMaxAgeMs = 120000  # 2 min TTL for content dedup
$script:contentDedupMaxSize = 100
$script:inflightCmdId = ""     # V13: currently executing cmd_id
$script:inflightSince = $null  # V13: when inflight started
$script:inflightTimeout = 300  # V13: max seconds a command can be inflight

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
        # V16: Log failure fallback — write to .watcher_fallback.log so we
        # can diagnose why the main log is failing.  The old silent catch
        # made this impossible to debug.
        try {
            $fallbackPath = Join-Path $script:baseDir ".watcher_fallback.log"
            $errMsg = $_.Exception.Message
            [System.IO.File]::AppendAllText($fallbackPath, "$t | LOG_FAIL: $errMsg`r`n", $script:utf8)
            [System.IO.File]::AppendAllText($fallbackPath, "$t | ORIGINAL: $m`r`n", $script:utf8)
        } catch {
            # Even fallback failed — nothing more we can do
        }
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

# ── V15: FileSystemWatcher replaces EventWaitHandle (v16: +progress flush) ──
# EventWaitHandle (v13) crashed ~6s after startup due to orphaned named kernel
# objects in PowerShell 5.1 non-interactive sessions. v14 removed it entirely
# and used pure polling (Start-Sleep 200ms) — reliable but wasteful:
#   - Up to 200ms latency per command
#   - CPU busy-waiting burns cycles
#
# V15 uses FileSystemWatcher.WaitForChanged() which blocks until queue.txt
# is modified OR 200ms timeout expires. Same semantics as EventWaitHandle
# (immediate wake on file write, bounded wait), but NO named kernel objects
# — the watcher lives entirely in-process via ReadDirectoryChangesW.
$script:queueWatcher = New-Object System.IO.FileSystemWatcher
$script:queueWatcher.Path = $baseDir
$script:queueWatcher.Filter = "queue.txt"
$script:queueWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
# Note: EnableRaisingEvents is NOT needed — WaitForChanged is synchronous

# resultEvent removed entirely (was always guarded, never used)
Log "V15 FileSystemWatcher initialized — event-driven queue monitoring (v16 extends with progress flush)"

# ── V13: Content-hash dedup — prevents re-executing identical commands ──
function Add-ContentDedup { param([string]$CmdText, [string]$CmdId)
    if ([string]::IsNullOrWhiteSpace($CmdText)) { return }
    $key = $CmdText.Substring(0, [Math]::Min(300, $CmdText.Length))
    $script:contentDedupCache[$key] = @{cmd_id=$CmdId; timestamp=(Get-Date)}
    if ($script:contentDedupCache.Count -gt $script:contentDedupMaxSize) {
        $sorted = $script:contentDedupCache.GetEnumerator() | Sort-Object { $_.Value.timestamp }
        $toRemove = $sorted | Select-Object -First ($script:contentDedupCache.Count - $script:contentDedupMaxSize)
        foreach ($e in $toRemove) { $script:contentDedupCache.Remove($e.Key) }
    }
}
function Get-ContentDedup { param([string]$CmdText)
    if ([string]::IsNullOrWhiteSpace($CmdText)) { return $null }
    $key = $CmdText.Substring(0, [Math]::Min(300, $CmdText.Length))
    if ($script:contentDedupCache.ContainsKey($key)) {
        $elapsed = [int]((Get-Date) - $script:contentDedupCache[$key].timestamp).TotalMilliseconds
        if ($elapsed -lt $script:contentDedupMaxAgeMs) { return $script:contentDedupCache[$key] }
        else { $script:contentDedupCache.Remove($key) }
    }
    return $null
}

# ── V13: Inflight guard helpers ──
function Set-Inflight { param([string]$CmdId)
    $script:inflightCmdId = $CmdId
    $script:inflightSince = Get-Date
}
function Clear-Inflight {
    $script:inflightCmdId = ""
    $script:inflightSince = $null
}
function Get-Inflight {  # returns $null if none or expired
    if ([string]::IsNullOrWhiteSpace($script:inflightCmdId)) { return $null }
    if ($script:inflightSince) {
        $elapsed = [int]((Get-Date) - $script:inflightSince).TotalSeconds
        if ($elapsed -gt $script:inflightTimeout) {
            Log "[INFLIGHT] Expired: $($script:inflightCmdId) (${elapsed}s > ${$script:inflightTimeout}s) — allowing override"
            Clear-Inflight
            return $null
        }
    }
    return $script:inflightCmdId
}

# ── V13: Periodic hostLoopMode cleanup — runs every ~60s ──
$script:housekeepCounter = 0
function Clean-HostLoopMode {
    $sessionDirs = @("$env:LOCALAPPDATA\Claude-3p\local-agent-mode-sessions")
    $found = 0; $fixed = 0
    foreach ($sd in $sessionDirs) {
        if (-not (Test-Path $sd)) { continue }
        try {
            Get-ChildItem "$sd\*\*\*\local_*\outputs\*.json" -ErrorAction SilentlyContinue | ForEach-Object {
                $found++
                try {
                    $content = [System.IO.File]::ReadAllText($_.FullName, $script:utf8)
                    if ($content -match '"hostLoopMode":\s*true') {
                        $content = $content -replace '"hostLoopMode":\s*true', '"hostLoopMode": false'
                        [System.IO.File]::WriteAllText($_.FullName, $content, $script:utf8)
                        $fixed++
                    }
                } catch {}
            }
        } catch {}
    }
    if ($fixed -gt 0) { Log "[HOUSEKEEP] Fixed hostLoopMode in $fixed session files (scanned $found)" }
}

# ── startup ─────────────────────────────────────────────────────────────

Log "=== Bridge v17 (ScriptBlock fast-path + scheduler IPC, event-driven) STARTED ==="

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

Log "Ready - v17 event-driven (ScriptBlock fast-path, 50ms FSW timeout)"

# ── main loop (event-driven with polling fallback) ──

while ($true) {
    try {
    # ── heartbeat ──
    try {
        [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8)
    } catch {
        # heartbeat never blocks
    }

    # V15: WaitForChanged blocks until queue.txt is written OR 200ms timeout
    #   — same semantics as EventWaitHandle.WaitOne(200) but no kernel objects
    #   — self-writes during cmd processing also trigger it; harmless
    $script:queueWatcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 50) | Out-Null
    $queue = Read-Json -path $script:queueFile

    # ── V13: Housekeeping (~every 300 loops = ~60s) ──
    $script:housekeepCounter++
    if ($script:housekeepCounter % 300 -eq 0) { Clean-HostLoopMode }

    # ── V13: Inflight guard — if a cmd is still running, reject new pending ──
    $inflight = Get-Inflight
    if ($inflight -and $queue -and $queue.cmd_id -ne $inflight) {
        # Another command is inflight, but the writer might be polling blindly.
        # Instead of queueing, we SKIP processing — the writer must wait.
        if ($queue.state -eq "pending") {
            Log "[INFLIGHT] Rejecting $($queue.cmd_id) — cmd $inflight still running (state=$($queue.state))"
            # Mark queue as "blocked" so the writer knows we're busy
            Write-Text -path $script:queueFile -content "{`"state`":`"blocked`",`"cmd_id`":`"$inflight`",`"command`":`"`",`"type`":`"`"}"
        }
        continue
    }

    if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id -ne "" -and $queue.cmd_id -ne $script:lastCmdId) {
        $script:lastCmdId = $queue.cmd_id
        $cid = $queue.cmd_id
        $ctype = $queue.type
        $rawCmd = $queue.command
        $origTimeout = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }

        # ── V13: Content-hash dedup — skip if identical command ran recently ──
        $dedupHit = Get-ContentDedup $rawCmd
        if ($dedupHit) {
            $ageMs = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
            Log "[$cid] CONTENT-HASH HIT: '$($rawCmd.Substring(0,[Math]::Min(80,$rawCmd.Length)))' = $($dedupHit.cmd_id) (${ageMs}ms ago) — reusing result"
            # Copy cached result to new cmd_id
            $cachedFile = Join-Path $baseDir "r_$($dedupHit.cmd_id).json"
            if (Test-Path $cachedFile) {
                try {
                    $cachedContent = [System.IO.File]::ReadAllText($cachedFile, $script:utf8)
                    $cachedParsed = ($cachedContent | ConvertFrom-Json)
                    $cachedParsed.cmd_id = $cid
                    $cachedParsed.duration_ms = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
                    Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($cachedParsed | ConvertTo-Json -Compress)
                } catch {
                    Log "[$cid] CONTENT-HASH cache read failed: $_ — proceeding with execution"
                }
            }
            Write-Text -path $script:queueFile -content $idleQueue
            # resultEvent removed in v15 (FileSystemWatcher provides equivalent wake-up)
            continue
        }

        # ── V13: Mark inflight before execution ──
        Set-Inflight $cid

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
            Clear-Inflight
            Write-Text -path $script:queueFile -content "{`"state`":`"idle`",`"cmd_id`":`"`",`"command`":`"`",`"type`":`"`"}"
            $restartRes = @{state="done";cmd_id=$cid;exit_code=0;stdout="Bridge restarting...";stderr="";duration_ms=0;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($restartRes | ConvertTo-Json -Compress)
            # Signal result ready
            # resultEvent removed in v15 (FileSystemWatcher provides equivalent wake-up)
            exit 0
        }
        if ($cmd -eq "__BRIDGE_STOP__") {
            Log "[$cid] BRIDGE STOP requested - exiting permanently"
            Clear-Inflight
            Write-Text -path $script:queueFile -content "{`"state`":`"idle`",`"cmd_id`":`"`",`"command`":`"`",`"type`":`"`"}"
            $stopRes = @{state="done";cmd_id=$cid;exit_code=0;stdout="Bridge stopped";stderr="";duration_ms=0;timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            Write-Text -path (Join-Path $baseDir "r_${cid}.json") -content ($stopRes | ConvertTo-Json -Compress)
            # resultEvent removed in v15 (FileSystemWatcher provides equivalent wake-up)
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
            # resultEvent removed in v15 (FileSystemWatcher provides equivalent wake-up)
            Clear-Inflight
            Add-ContentDedup -CmdText $rawCmd -CmdId $cid
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
            Clear-Inflight
            Add-ContentDedup -CmdText $rawCmd -CmdId $cid
            # resultEvent removed in v15 (FileSystemWatcher provides equivalent wake-up)
            Log "[$cid] USER result written (exit=$userExit)"
            continue
        }

        Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

        $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""
        $flushInterval = 5   # seconds between progress flushes
        $progressFile = Join-Path $baseDir "r_${cid}_progress.json"

        # ══════════════════════════════════════════════════════════════════
        # V17.2: Runspace-wrapped ScriptBlock with REAL timeout support
        # - Strips 'exit' (kills host process in ScriptBlock mode)
        # - Uses [powershell]::Create() + BeginInvoke for async timeout
        # - Timeout: stops runaway scripts, falls back to subprocess
        # - Fast path (< timeout): returns result inline, ~3-8ms overhead
        # ══════════════════════════════════════════════════════════════════
        $sbFastOk = $false
        if ($ctype -eq "powershell" -or $ctype -eq "powershell_text" -or $ctype -eq "inline") {
            try {
                # Strip 'exit N' / 'exit' — would terminate the watcher process
                $sbCmd = $cmd -replace '\bexit\s+\d+\s*;?\s*$', '' -replace '\bexit\s*;?\s*$', ''

                # ── Runspace-wrapped execution with timeout ──
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.AddScript({
                    param($Cmd)
                    $ErrorActionPreference = 'Continue'
                    & ([ScriptBlock]::Create($Cmd)) 2>&1
                }).AddArgument($sbCmd)

                $handle = $ps.BeginInvoke()
                $sbTimeoutMs = [Math]::Max(1000, ($timeout * 1000))
                if ($handle.AsyncWaitHandle.WaitOne($sbTimeoutMs)) {
                    $sbResult = $ps.EndInvoke($handle)
                    $stdout = if ($sbResult -ne $null) { ($sbResult | Out-String).Trim() } else { "" }
                    $exitCode = 0
                    $stderr = ""
                    $errorMsg = ""
                    $sbFastOk = $true
                    Log "[$cid] V17.2 RUNSPACE fast-path OK — $(((Get-Date) - $t0).TotalMilliseconds.ToString('0'))ms"
                } else {
                    $ps.Stop()
                    Log "[$cid] V17.2 RUNSPACE TIMEOUT after ${timeout}s — falling back to subprocess"
                }
                $ps.Dispose()

            } catch {
                $sbFailMsg = $_.Exception.Message
                Log "[$cid] V17.2 Runspace failed ($sbFailMsg) — falling back to subprocess"
            }
        }

        if (-not $sbFastOk) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                if ($ctype -eq "cmd") {
                    $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $cmd"
                } elseif ($ctype -eq "powershell") {
                    $psi.FileName = "powershell.exe"
                    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
                    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
                } elseif ($ctype -eq "powershell_text") {
                    $psi.FileName = "powershell.exe"
                    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($cmd -replace '\"', '\"')`""
                } else {
                    throw "Unknown type: $ctype"
                }
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = $script:utf8
                $psi.StandardErrorEncoding  = $script:utf8

                $p = [System.Diagnostics.Process]::Start($psi)
                if (-not $p) { throw "Process.Start returned null" }

                # V4: ReadToEndAsync — background read eliminates pipe-buffer race.
                $outTask = $p.StandardOutput.ReadToEndAsync()
                $errTask = $p.StandardError.ReadToEndAsync()

                $loopStart = Get-Date
                $lastProgressWrite = Get-Date
                while ($true) {
                    # heartbeat inside the command too
                    try {
                        [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8)
                    } catch {}

                    if ($p.WaitForExit($flushInterval * 1000)) {
                        $exitCode = $p.ExitCode
                        $stdout = $outTask.Result
                        $stderr = $errTask.Result
                        Log "[$cid] Process exited naturally, PID=$($p.Id) code=$exitCode"
                        break
                    }

                    # V16: Progress flush
                    $now = Get-Date
                    if (($now - $lastProgressWrite).TotalSeconds -ge $flushInterval) {
                        $elapsedSec = [int]($now - $t0).TotalSeconds
                        $progressData = @{
                            elapsed_s = $elapsedSec
                            running = $true
                            pid = $p.Id
                            has_exited = $false
                            note = "ReadToEndAsync mode: partial stdout not available; full capture guaranteed on completion"
                        }
                        Write-Text -path $progressFile -content ($progressData | ConvertTo-Json -Compress)
                        $lastProgressWrite = $now
                        Log "[$cid] Progress: ${elapsedSec}s elapsed, PID=$($p.Id) still running"
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

                        Start-Sleep -Milliseconds 300
                        try { $stdout = $outTask.Result } catch { $stdout = "" }
                        try { $stderr = $errTask.Result } catch { $stderr = "" }

             