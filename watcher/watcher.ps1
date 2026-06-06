#Requires -Version 5.0
<#
.SYNOPSIS
    Claude Bridge V22 — Refactored watcher using shared modules.
.DESCRIPTION
    Main loop extracted into named handler functions for clarity and maintainability.
    Uses BridgeCommon.psm1 for file I/O, logging, heartbeat, queue helpers.
    Uses BridgeExecution.psm1 for command execution utilities.

    Key changes from V19:
    - Module imports replace inline Write-Text/Read-Json/Log (eliminates duplication)
    - Main loop uses 9 extracted handler functions instead of 383 inline lines
    - Result writing uses New-CommandResult/Write-CommandResult from BridgeCommon
    - Queue reset uses Reset-QueueToIdle from BridgeCommon

    Feature history:
    V21: Named Pipe Async Dispatch with inflight tracking
    V17: ScriptBlock in-process fast path (~10ms vs ~150ms subprocess)
    V16: Progress flush for long-running commands
    V15: FileSystemWatcher replaces EventWaitHandle (no kernel object crashes)
#>

# ══════════════════════════════════════════════════════════════════
# Base paths
# ══════════════════════════════════════════════════════════════════
$script:baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:queueFile = Join-Path $script:baseDir "queue.txt"
$script:logFile = Join-Path $script:baseDir "watcher.log"
$script:heartbeatFile = Join-Path $script:baseDir ".watcher_heartbeat"
$script:rulesFile = Join-Path $script:baseDir "bridge_rules.json"
$script:errorHistoryFile = Join-Path $script:baseDir "error_history.json"
$script:utf8 = [System.Text.UTF8Encoding]::new($false)

# ══════════════════════════════════════════════════════════════════
# Module imports (BridgeCommon + BridgeExecution)
# ══════════════════════════════════════════════════════════════════
$modulesDir = Join-Path (Split-Path -Parent $script:baseDir) "modules"
Import-Module (Join-Path $modulesDir "BridgeCommon.psm1") -Force
Import-Module (Join-Path $modulesDir "BridgeExecution.psm1") -Force

# ── Wrapper + aliases for backward compatibility ──
# Log wraps Write-BridgeLog with the log file path + fallback diagnostics
function Log { param([string]$m)
    try {
        Write-BridgeLog -Message $m -LogFile $script:logFile
    } catch {
        try {
            $fallbackPath = Join-Path $script:baseDir ".watcher_fallback.log"
            $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            [System.IO.File]::AppendAllText($fallbackPath, "$t | LOG_FAIL: $($_.Exception.Message)`r`n", $script:utf8)
            [System.IO.File]::AppendAllText($fallbackPath, "$t | ORIGINAL: $m`r`n", $script:utf8)
        } catch {}
    }
}
Set-Alias Write-Text  Write-SafeFile
Set-Alias Read-Json   Read-SafeJson

# ══════════════════════════════════════════════════════════════════
# State variables
# ══════════════════════════════════════════════════════════════════
$script:lastCmdId = ""
$script:rulesCache = $null
$script:cmdCounter = 0

# Self-upgrade tracking
$script:watcherScriptPath = $MyInvocation.MyCommand.Path
$script:watcherScriptLastWrite = (Get-Item $script:watcherScriptPath).LastWriteTime
$script:watcherStartTime = Get-Date
$script:selfUpgradeCounter = 0
$script:selfUpgradeCheckInterval = 50  # check every ~50 main-loop iterations (~2.5s)
$script:restartFlagFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) ".graceful_restart"

# Housekeeping
$script:housekeepCounter = 0
$script:guardianCheckCounter = 0
$script:guardianTaskName = "BridgeGuardian-V3"
$script:registerGuardianScript = Join-Path (Split-Path -Parent $script:baseDir) "cluster\register_guardian_v3.ps1"

# V21 inflight tracking
$script:inflight = @{}

# Worker pool
$script:poolFile = Join-Path (Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent) "cluster\.worker_pool.json"
$script:pool = $null
$script:poolLastLoad = $null
$script:workerRR = @{}

# ══════════════════════════════════════════════════════════════════
# Rule engine loading
# ══════════════════════════════════════════════════════════════════
$script:ruleEnginePath = Join-Path (Split-Path -Parent $script:baseDir) "cluster\rule_engine.ps1"
if (Test-Path $script:ruleEnginePath) {
    . $script:ruleEnginePath
    Init-RuleEngine -BridgeBase (Split-Path -Parent $script:baseDir)
    Log "Rule engine loaded from $($script:ruleEnginePath)"
} else {
    Log "WARNING: Rule engine not found at $($script:ruleEnginePath) — using legacy functions"
}

# ── Legacy rule application (fallback when shared engine unavailable) ──
function Legacy-ApplyRules { param([string]$cmd, [string]$ctype)
    if (Get-Command "Apply-Rules" -Module $null -ErrorAction SilentlyContinue | Where-Object { $_.ScriptBlock.ToString() -match 'RE_baseDir' }) {
        return $cmd
    }

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

# ══════════════════════════════════════════════════════════════════
# Error learning — log issues for pattern analysis
# ══════════════════════════════════════════════════════════════════
function Log-Error { param([string]$cid, [string]$ctype, [string]$cmd, [int]$exitCode, [string]$stdoutText, [string]$stderrText)
    $historyPath = $script:errorHistoryFile
    $needLearning = $false
    $issueDesc = ""

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
        $needLearning = $true
        $issueDesc = "zero_exit_with_no_output"
    } elseif ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stderrText)) {
        $needLearning = $true
        $issueDesc = "stderr_with_success_exit"
    }

    if (-not $needLearning) { return }

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

    try {
        $existing = @{version="1.0"; errors=@()}
        if (Test-Path $historyPath) {
            $existingText = [System.IO.File]::ReadAllText($historyPath, $script:utf8)
            if (-not [string]::IsNullOrWhiteSpace($existingText)) {
                $existing = ($existingText | ConvertFrom-Json)
            }
        }
        $existing.errors += $entry
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

# ══════════════════════════════════════════════════════════════════
# Startup cleanup + PID lock
# ══════════════════════════════════════════════════════════════════
Get-ChildItem "$script:baseDir\*.tmp" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$lockFile = Join-Path $script:baseDir ".watcher.lock"
if (Test-Path $lockFile) {
    try {
        $oldPid = [int]([System.IO.File]::ReadAllText($lockFile, $script:utf8).Trim())
        $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($oldProc -and $oldProc.ProcessName -match "powershell") {
            Log "Another watcher PID=$oldPid already running - exiting"
            exit 0
        }
    } catch { }
}
try {
    [System.IO.File]::WriteAllText($lockFile, [string]$PID, $script:utf8)
    Log "PID lock acquired: $PID"
} catch {
    Log "WARNING: could not write lock file: $_"
}

# ══════════════════════════════════════════════════════════════════
# FileSystemWatcher — event-driven queue monitoring
# ══════════════════════════════════════════════════════════════════
$script:queueWatcher = New-Object System.IO.FileSystemWatcher
$script:queueWatcher.Path = $script:baseDir
$script:queueWatcher.Filter = "queue.txt"
$script:queueWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite

Log "V22 FileSystemWatcher initialized — event-driven queue monitoring"

# ══════════════════════════════════════════════════════════════════
# Content-hash dedup (V21: DISABLED — structure preserved)
# ══════════════════════════════════════════════════════════════════
function Add-ContentDedup { param([string]$CmdText, [string]$CmdId) }
function Get-ContentDedup { param([string]$CmdText) return $null }

# ══════════════════════════════════════════════════════════════════
# Inflight tracking — V21 concurrent command management
# ══════════════════════════════════════════════════════════════════
function Add-Inflight { param([string]$CmdId, $Worker, [string]$Ctype, [int]$Timeout)
    $script:inflight[$CmdId] = @{
        worker = $Worker
        type = $Ctype
        start = Get-Date
        timeout = $Timeout
    }
    Log "[$CmdId] INFLIGHT added — $Ctype → $($Worker.id) (${Timeout}s timeout)"
}

function Remove-Inflight { param([string]$CmdId)
    $script:inflight.Remove($CmdId)
}

function Get-InflightCount { return $script:inflight.Count }

function Check-InflightResults {
    $completed = 0
    $toRemove = @()

    foreach ($cid in $script:inflight.Keys) {
        $info = $script:inflight[$cid]
        $elapsed = [int]((Get-Date) - $info.start).TotalSeconds

        if ($elapsed -gt ($info.timeout + 5)) {
            Log "[$cid] INFLIGHT TIMEOUT after ${elapsed}s (>$($info.timeout)s)"
            $toRemove += $cid
            $completed++
            continue
        }

        $rFile = Join-Path $script:baseDir "r_${cid}.json"
        if (Test-Path $rFile) {
            $content = Read-Json -path $rFile
            if ($content) {
                Log "[$cid] INFLIGHT COMPLETE — exit=$($content.exit_code) dur=$($content.duration_ms)ms"
                $toRemove += $cid
                $completed++
            }
        }
    }

    foreach ($cid in $toRemove) {
        $script:inflight.Remove($cid)
    }

    return $completed
}

# ══════════════════════════════════════════════════════════════════
# Housekeeping — periodic cleanup tasks
# ══════════════════════════════════════════════════════════════════
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

function Assert-GuardianTask {
    $script:guardianCheckCounter++
    if ($script:guardianCheckCounter % 300 -ne 0) { return }

    try {
        $taskOutput = schtasks /Query /FO CSV /NH /TN "$script:guardianTaskName" 2>&1
        if ($LASTEXITCODE -eq 0 -and $taskOutput -match "$script:guardianTaskName") {
            Log "[GUARDIAN] Task '$script:guardianTaskName' is registered — healthy"
        } else {
            throw "Task not found in query output"
        }
    } catch {
        Log "[GUARDIAN] Task '$script:guardianTaskName' NOT registered — attempting re-registration..."
        if (Test-Path $script:registerGuardianScript) {
            try {
                $proc = Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$script:registerGuardianScript`"",
                    "-Force"
                ) -PassThru -Wait
                Log "[GUARDIAN] Re-registration exit code: $($proc.ExitCode)"
            } catch {
                Log "[GUARDIAN] Re-registration failed: $($_.Exception.Message)"
            }
        } else {
            Log "[GUARDIAN] Registration script not found at $script:registerGuardianScript"
        }
    }
}

# ══════════════════════════════════════════════════════════════════
# Worker pool + Named Pipe dispatch
# ══════════════════════════════════════════════════════════════════
function Get-WorkerPool {
    $now = Get-Date
    if (-not $script:pool -or -not $script:poolLastLoad -or (($now - $script:poolLastLoad).TotalSeconds -gt 30)) {
        $p = Read-Json -path $script:poolFile
        if ($p -and $p.workers -and $p.workers.Count -gt 0) {
            $script:pool = $p
            $script:poolLastLoad = $now
        }
    }
    return $script:pool
}

function Get-WorkerForType {
    param([string]$ctype)

    $pool = Get-WorkerPool
    if (-not $pool -or -not $pool.workers) { return $null }

    $targetType = switch ($ctype) {
        "wsl"   { "wsl" }
        "user"  { "user" }
        "file"  { "file" }
        "process" { "process" }
        "system" { "system" }
        default { "generic" }
    }

    $candidates = @($pool.workers | Where-Object {
        $_.type -eq $targetType -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue)
    })

    if ($candidates.Count -eq 0 -and $targetType -ne "generic") {
        Log "[DISPATCH] No '$targetType' worker — falling back to generic"
        $candidates = @($pool.workers | Where-Object {
            $_.type -eq "generic" -and (Get-Process -Id $_.pid -ErrorAction SilentlyContinue)
        })
    }

    if ($candidates.Count -eq 0) { return $null }

    $busyWorkerIds = @($script:inflight.Values | ForEach-Object { $_.worker.id })
    $available = @($candidates | Where-Object { $_.id -notin $busyWorkerIds })
    if ($available.Count -gt 0) { $candidates = $available }

    $idx = [Math]::Max(0, $script:workerRR[$targetType])
    $script:workerRR[$targetType] = ($idx + 1) % $candidates.Count
    return $candidates[$idx % $candidates.Count]
}

function Dispatch-ToWorker {
    param([string]$cid, [string]$ctype, [string]$cmd, [int]$timeout)

    $worker = Get-WorkerForType -ctype $ctype
    if (-not $worker) {
        Log "[$cid] No worker available for type '$ctype'"
        return $null
    }

    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $worker.pipe, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(2000)
        $reader = New-Object System.IO.StreamReader($pipe, $script:utf8)
        $writer = New-Object System.IO.StreamWriter($pipe, $script:utf8)
        $writer.AutoFlush = $true

        $cmdJson = @{cmd_id=$cid; command=$cmd; type=$ctype; timeout=$timeout} | ConvertTo-Json -Compress
        $writer.WriteLine($cmdJson)

        $ackTask = $reader.ReadLineAsync()
        $gotAck = $ackTask.Wait(100)

        $pipe.Close()
        if ($gotAck) {
            Log "[$cid] DISPATCH to $($worker.id) — ACK received"
        } else {
            Log "[$cid] DISPATCH to $($worker.id) — sent (no ACK, assumed delivered)"
        }
        return $worker
    } catch {
        Log "[$cid] DISPATCH to $($worker.id) failed: $($_.Exception.Message)"
        return $null
    }
}

# ══════════════════════════════════════════════════════════════════
# Extracted handler functions (V22 refactoring)
# ══════════════════════════════════════════════════════════════════

function Invoke-Housekeeping {
    <#.SYNOPSIS Periodic cleanup tasks (~every 60s)#>
    param([int]$Counter)
    if ($Counter % 300 -eq 0) {
        Clean-HostLoopMode
        Assert-GuardianTask
    }
}

function Invoke-PollInflight {
    <#.SYNOPSIS Check for completed async dispatch results and reset queue if all done.#>
    $completedCount = Check-InflightResults
    if ($completedCount -gt 0 -and (Get-InflightCount) -eq 0) {
        $idleCheck = Read-Json -path $script:queueFile
        if ($idleCheck -and ($idleCheck.state -eq "running" -or $idleCheck.state -eq "blocked")) {
            Reset-QueueToIdle -Path $script:queueFile
            Log "[INFLIGHT] All commands completed — queue reset to idle"
        }
    }
}

function Invoke-HandleDedup {
    <#.SYNOPSIS Check content-hash dedup. Returns $true if dedup hit (command skipped).#>
    param([string]$CmdId, [string]$RawCmd)
    $dedupHit = Get-ContentDedup $RawCmd
    if (-not $dedupHit) { return $false }

    $ageMs = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
    Log "[$CmdId] CONTENT-HASH HIT: '$($RawCmd.Substring(0,[Math]::Min(80,$RawCmd.Length)))' = $($dedupHit.cmd_id) (${ageMs}ms ago) — reusing result"
    $cachedFile = Join-Path $script:baseDir "r_$($dedupHit.cmd_id).json"
    if (Test-Path $cachedFile) {
        try {
            $cachedContent = [System.IO.File]::ReadAllText($cachedFile, $script:utf8)
            $cachedParsed = ($cachedContent | ConvertFrom-Json)
            $cachedParsed.cmd_id = $CmdId
            $cachedParsed.duration_ms = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
            Write-Text -path (Join-Path $script:baseDir "r_${CmdId}.json") -content ($cachedParsed | ConvertTo-Json -Compress)
        } catch {
            Log "[$CmdId] CONTENT-HASH cache read failed: $_ — proceeding with execution"
            return $false
        }
    }
    Reset-QueueToIdle -Path $script:queueFile
    return $true
}

function Invoke-ApplyRules {
    <#.SYNOPSIS Apply rule engine transformations to a command.#>
    param([string]$Cmd, [string]$Type, [string]$CmdId)
    $ruleResult = if (Get-Command "Init-RuleEngine" -ErrorAction SilentlyContinue) {
        Apply-Rules -Cmd $Cmd -Type $Type
    } else {
        @{cmd=(Legacy-ApplyRules -cmd $Cmd -ctype $Type); type=$Type; applied=@()}
    }
    if ($ruleResult.type -ne $Type) {
        Log "[$CmdId] TYPE CHANGED: $Type -> $($ruleResult.type)"
    }
    if ($ruleResult.cmd -ne $Cmd) {
        Log "[$CmdId] TRANSFORMED: '$Cmd' -> '$($ruleResult.cmd)' (rules: $($ruleResult.applied -join ','))"
    }
    return $ruleResult
}

function Invoke-MetaCommand {
    <#.SYNOPSIS Handle __BRIDGE_RESTART__ and __BRIDGE_STOP__. Returns $true if handled.#>
    param([string]$Cmd, [string]$CmdId)
    if ($Cmd -eq "__BRIDGE_RESTART__") {
        Log "[$CmdId] BRIDGE RESTART requested — launching restarter, then exiting"
        $restarterScript = Join-Path (Split-Path -Parent $script:watcherScriptPath) "restarter.ps1"
        if (Test-Path $restarterScript) {
            try {
                $restarterProc = Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$restarterScript`"",
                    "-OldPID", [string]$PID,
                    "-WatcherPath", "`"$script:watcherScriptPath`"",
                    "-LogFile", "`"$script:logFile`""
                ) -PassThru
                Log "[$CmdId] Restarter launched PID=$($restarterProc.Id)"
            } catch {
                Log "[$CmdId] Failed to launch restarter: $($_.Exception.Message) — guardian fallback"
            }
        }
        Reset-QueueToIdle -Path $script:queueFile
        $restartRes = New-CommandResult -CmdId $CmdId -ExitCode 0 -Stdout "Bridge restarting..."
        Write-CommandResult -Result $restartRes -Directory $script:baseDir
        try { Remove-Item (Join-Path $script:baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
        exit 0
    }
    if ($Cmd -eq "__BRIDGE_STOP__") {
        Log "[$CmdId] BRIDGE STOP requested - exiting permanently"
        $script:inflight = @{}
        Reset-QueueToIdle -Path $script:queueFile
        $stopRes = New-CommandResult -CmdId $CmdId -ExitCode 0 -Stdout "Bridge stopped"
        Write-CommandResult -Result $stopRes -Directory $script:baseDir
        try { Remove-Item (Join-Path $script:baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
        exit 0
    }
    return $false
}

function Invoke-InlineExecution {
    <#.SYNOPSIS Handle __INLINE__ type — execute PowerShell directly in-process.#>
    param([string]$CmdId, [string]$RawCmd, [datetime]$StartTime)

    Log "[$CmdId] INLINE execution requested"
    $inlineExit = 0; $inlineOut = ""; $inlineErr = ""; $inlineError = ""
    try {
        $scriptBlock = [ScriptBlock]::Create($RawCmd)
        $inlineResult = & $scriptBlock
        if ($inlineResult -ne $null) {
            $inlineOut = ($inlineResult | Out-String).Trim()
        }
        Log "[$CmdId] INLINE succeeded"
    } catch {
        $inlineErr = $_.Exception.Message
        $inlineExit = -1
        $inlineError = $_.Exception.Message
        Log "[$CmdId] INLINE exception: $inlineErr"
    }

    $inlineRes = New-CommandResult -CmdId $CmdId -ExitCode $inlineExit `
        -Stdout $inlineOut -Stderr $inlineErr -Error $inlineError `
        -DurationMs ([int]((Get-Date) - $StartTime).TotalMilliseconds)
    if ($inlineError) { $inlineRes.state = "error" }
    Reset-QueueToIdle -Path $script:queueFile
    Write-CommandResult -Result $inlineRes -Directory $script:baseDir
    $script:inflight.Remove($CmdId)
    Add-ContentDedup -CmdText $RawCmd -CmdId $CmdId
    Log "[$CmdId] INLINE result written"
}

function Invoke-UserContextExecution {
    <#.SYNOPSIS Route 'user' type commands to user_bridge worker.#>
    param([string]$CmdId, [string]$Cmd, [int]$Timeout, [datetime]$StartTime)

    Log "[$CmdId] USER-context execution via user_bridge"
    $userQueue = Join-Path (Split-Path $script:baseDir -Parent) "cluster\user_bridge\queue.txt"
    $userResult = Join-Path (Split-Path $script:baseDir -Parent) "cluster\user_bridge\r_${CmdId}.json"

    $userCmd = @{state="pending";cmd_id=$CmdId;command=$Cmd;type="powershell";timeout=$Timeout} | ConvertTo-Json -Compress
    Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$CmdId`"}"
    Write-Text -path $userQueue -content $userCmd

    $deadline = (Get-Date).AddSeconds($Timeout + 5)
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

    $userRes = New-CommandResult -CmdId $CmdId -ExitCode $userExit `
        -Stdout $userOut -Stderr $userErr -Error $userError `
        -DurationMs ([int]((Get-Date) - $StartTime).TotalMilliseconds)
    if ($userError) { $userRes.state = "error" }
    Reset-QueueToIdle -Path $script:queueFile
    Write-CommandResult -Result $userRes -Directory $script:baseDir
    $script:inflight.Remove($CmdId)
    Add-ContentDedup -CmdText $Cmd -CmdId $CmdId
    Log "[$CmdId] USER result written (exit=$userExit)"
}

function Invoke-InprocessFallback {
    <#.SYNOPSIS Execute command in-process when no worker is available.#>
    param([string]$CmdId, [string]$RawCmd, [string]$Ctype, [int]$Timeout)

    $subT0 = Get-Date
    $progressFile = Join-Path $script:baseDir "r_${CmdId}_progress.json"
    $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""
    $fastPath = $false

    # ── ScriptBlock fast path (for powershell/powershell_text/inline) ──
    if ($Ctype -eq "powershell" -or $Ctype -eq "powershell_text" -or $Ctype -eq "inline") {
        try {
            $sbCmd = $RawCmd -replace '\bexit\s+\d+\s*;?\s*$', '' -replace '\bexit\s*;?\s*$', ''
            $ps = [PowerShell]::Create()
            $ps.AddScript({ param($c) & ([ScriptBlock]::Create($c)) 2>&1 }).AddArgument($sbCmd)
            $h = $ps.BeginInvoke()
            $tMs = [Math]::Max(1000, ($Timeout * 1000))
            if ($h.AsyncWaitHandle.WaitOne($tMs)) {
                $r = $ps.EndInvoke($h)
                $stdout = if ($r) { ($r | Out-String).Trim() } else { "" }
                $exitCode = 0; $fastPath = $true
                $elapsed = [int]((Get-Date) - $subT0).TotalMilliseconds
                Log "  [$CmdId] RUNSPACE fast-path OK — ${elapsed}ms"
            } else {
                $ps.Stop()
                $errorMsg = "TIMEOUT after ${Timeout}s"
                $stdout = "[TIMEOUT]"
                Log "  [$CmdId] RUNSPACE TIMEOUT after ${Timeout}s — subprocess fallback"
            }
            $ps.Dispose()
        } catch {
            Log "  [$CmdId] RUNSPACE exception: $($_.Exception.Message) — subprocess fallback"
        }
    }

    # ── Subprocess fallback (all types) ──
    if (-not $fastPath) {
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            if ($Ctype -eq "cmd") {
                $psi.FileName = "cmd.exe"; $psi.Arguments = "/c $RawCmd"
            } elseif ($Ctype -eq "wsl") {
                $psi.FileName = "wsl.exe"
                $psi.Arguments = "-e bash -c `"$($RawCmd -replace '"', '\"')`""
            } else {
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($RawCmd -replace '"', '\"')`""
            }
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = $script:utf8; $psi.StandardErrorEncoding = $script:utf8

            $p = [System.Diagnostics.Process]::Start($psi)
            if (-not $p) { throw "Process.Start returned null" }
            Log "  [$CmdId] Subprocess started PID=$($p.Id), timeout=${Timeout}s"

            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()

            $loopStart = Get-Date
            $lastProgressWrite = Get-Date
            $timedOut = $false

            while ($true) {
                try { [System.IO.File]::WriteAllText($script:heartbeatFile, (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $script:utf8) } catch {}

                if ($p.WaitForExit(5000)) {
                    $exitCode = $p.ExitCode
                    $stdout = $outTask.Result
                    $stderr = $errTask.Result
                    Log "  [$CmdId] Process exited naturally, PID=$($p.Id) code=$exitCode"
                    break
                }

                $now = Get-Date
                if (($now - $lastProgressWrite).TotalSeconds -ge 5) {
                    $elapsedSec = [int]($now - $loopStart).TotalSeconds
                    $progressData = @{
                        state = "running"
                        cmd_id = $CmdId
                        elapsed_seconds = $elapsedSec
                        timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss.fff")
                    }
                    Write-Text -path $progressFile -content ($progressData | ConvertTo-Json -Compress)
                    $lastProgressWrite = $now
                    Log "  [$CmdId] Progress: ${elapsedSec}s elapsed, PID=$($p.Id) still running"
                }

                if (($now - $loopStart).TotalSeconds -gt ($Timeout + 5)) {
                    $timedOut = $true
                    Log "  [$CmdId] TIMEOUT after ${Timeout}s — killing PID $($p.Id)"
                    try {
                        $p.Kill()
                        if (-not $p.WaitForExit(3000)) {
                            Log "  [$CmdId] Kill didn't finish in 3s, continuing..."
                        }
                    } catch { Log "  [$CmdId] Kill exception: $_" }
                    Start-Sleep -Milliseconds 300
                    try { $stdout = $outTask.Result } catch { $stdout = "" }
                    try { $stderr = $errTask.Result } catch { $stderr = "" }
                    break
                }
            }

            if ($timedOut) {
                $exitCode = -1; $errorMsg = "TIMEOUT after ${Timeout}s"
            }
            try { Remove-Item $progressFile -Force -ErrorAction SilentlyContinue } catch {}
            $p.Dispose()
        } catch {
            $errorMsg = $_.Exception.Message
            Log "  [$CmdId] Subprocess exception: $errorMsg"
        }
    }

    # Build and write result
    $elapsed = [int]((Get-Date) - $subT0).TotalMilliseconds
    $res = New-CommandResult -CmdId $CmdId -ExitCode $exitCode `
        -Stdout $stdout -Stderr $stderr -Error $errorMsg `
        -DurationMs $elapsed -FastPath $fastPath
    if ($errorMsg) { $res.state = "error" }
    Write-CommandResult -Result $res -Directory $script:baseDir
    Reset-QueueToIdle -Path $script:queueFile
    Add-ContentDedup -CmdText $RawCmd -CmdId $CmdId
    Log "  [$CmdId] result written (exit=$exitCode, dur=${elapsed}ms, fast=$fastPath)"
}

function Test-SelfUpgrade {
    <#.SYNOPSIS Check if watcher.ps1 has changed on disk and trigger graceful restart.#>
    $script:selfUpgradeCounter++
    if ($script:selfUpgradeCounter -ge $script:selfUpgradeCheckInterval) {
        $script:selfUpgradeCounter = 0
        try {
            $currentWrite = (Get-Item $script:watcherScriptPath).LastWriteTime
            if ($currentWrite -gt $script:watcherScriptLastWrite) {
                Log "[SELF-UPGRADE] watcher.ps1 changed on disk — initiating graceful restart"
                Write-Text -path $script:restartFlagFile -content ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"))
                $restartCmd = @{
                    state = "pending"
                    cmd_id = "__SELF_UPGRADE_$(Get-Date -Format 'yyyyMMddHHmmss')__"
                    type = "__BRIDGE_RESTART__"
                    command = ""
                    timeout = 10
                }
                Write-Text -path $script:queueFile -content ($restartCmd | ConvertTo-Json -Compress)
            }
        } catch {
            Log "[SELF-UPGRADE] Check failed: $_"
        }
    }
}

# ══════════════════════════════════════════════════════════════════
# Startup — initialize queue + log readiness
# ══════════════════════════════════════════════════════════════════
Log "=== Bridge V22 (shared modules + extracted handlers) STARTED ==="

$existing = Read-Json -path $script:queueFile
if (-not $existing) {
    Reset-QueueToIdle -Path $script:queueFile
    Log "Queue created (no existing file)"
} elseif ($existing.state -eq "pending") {
    Log "Pending command preserved: $($existing.cmd_id) / $($existing.command)"
} else {
    Reset-QueueToIdle -Path $script:queueFile
    Log "Queue reset from state=$($existing.state)"
}

Log "Ready — V22 event-driven (shared modules, ScriptBlock fast-path, 50ms FSW timeout)"

# ══════════════════════════════════════════════════════════════════
# Main loop — event-driven with polling fallback
# ══════════════════════════════════════════════════════════════════
while ($true) {
    try {
        # 1. Heartbeat
        Write-Heartbeat -Path $script:heartbeatFile

        # 2. Wait for queue change (blocks until write OR 50ms timeout)
        $script:queueWatcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 50) | Out-Null
        $queue = Read-Json -path $script:queueFile

        # 3. Periodic housekeeping (~every 300 loops = ~60s)
        $script:housekeepCounter++
        Invoke-Housekeeping -Counter $script:housekeepCounter

        # 4. Poll for completed inflight results
        Invoke-PollInflight

        # 5. Process pending command
        if ($queue -and $queue.state -eq "pending" -and $queue.cmd_id -ne "" -and $queue.cmd_id -ne $script:lastCmdId) {
            $script:lastCmdId = $queue.cmd_id
            $cid = $queue.cmd_id
            $ctype = $queue.type
            $rawCmd = $queue.command
            $origTimeout = if ($queue.timeout -gt 0) { $queue.timeout } else { 30 }
            $t0 = Get-Date

            # 5a. Dedup check
            if (Invoke-HandleDedup -CmdId $cid -RawCmd $rawCmd) { continue }

            # 5b. Rule engine
            $ruleResult = Invoke-ApplyRules -Cmd $rawCmd -Type $ctype -CmdId $cid
            $cmd = $ruleResult.cmd
            if ($ruleResult.type -ne $ctype) { $ctype = $ruleResult.type }
            Log "[$cid] type=$ctype cmd=$cmd timeout=${origTimeout}s"

            # 5c. Meta-commands (restart/stop)
            if (Invoke-MetaCommand -Cmd $cmd -CmdId $cid) { continue }

            # 5d. Inline execution
            if ($ctype -eq "__INLINE__") { Invoke-InlineExecution -CmdId $cid -RawCmd $rawCmd -StartTime $t0; continue }

            # 5e. User-context execution
            if ($ctype -eq "user") { Invoke-UserContextExecution -CmdId $cid -Cmd $cmd -Timeout $origTimeout -StartTime $t0; continue }

            # 5f. Mark running
            Write-Text -path $script:queueFile -content "{`"state`":`"running`",`"cmd_id`":`"$cid`"}"

            # 5g. Named Pipe dispatch (async)
            $pipeDispatched = $false
            $worker = Dispatch-ToWorker -cid $cid -ctype $ctype -cmd $cmd -timeout $origTimeout
            if ($worker) {
                Add-Inflight -CmdId $cid -Worker $worker -Ctype $ctype -Timeout $origTimeout
                $pipeDispatched = $true
                Reset-QueueToIdle -Path $script:queueFile
                Log "[$cid] V22 ASYNC-DISPATCH to $($worker.id) — inflight"
            }

            # 5h. In-process fallback
            if (-not $pipeDispatched) {
                Invoke-InprocessFallback -CmdId $cid -RawCmd $rawCmd -Ctype $ctype -Timeout $origTimeout
                Test-SelfUpgrade
            }
        }
    } catch {
        Log "[FATAL] Main loop exception: $($_.Exception.ToString())"
        Start-Sleep -Seconds 1
    }
}
