<#
.SYNOPSIS
    Watcher v22 — Refactored main loop using shared modules.
.DESCRIPTION
    This file shows the refactored main loop structure. To apply:
    1. Replace Write-Text/Read-Json/Log with BridgeCommon module calls
    2. Replace inline ScriptBlock/subprocess code with BridgeExecution calls
    3. Extract handlers into named functions

    Key changes from v19:
    - Uses BridgeCommon.psm1 for file I/O, logging, heartbeat
    - Uses BridgeExecution.psm1 for command execution
    - Main loop is 10 named function calls instead of 383 inline lines
#>

# ── Module imports (add at top of watcher.ps1) ──
$modulesDir = Join-Path (Split-Path -Parent $script:baseDir) "modules"
Import-Module (Join-Path $modulesDir "BridgeCommon.psm1") -Force
Import-Module (Join-Path $modulesDir "BridgeExecution.psm1") -Force

# ── Aliases for backward compatibility ──
# Other code in watcher.ps1 calls Write-Text/Read-Json/Log — these aliases
# redirect to the module versions without changing every call site.
Set-Alias Write-Text  Write-SafeFile
Set-Alias Read-Json   Read-SafeJson
Set-Alias Log         Write-BridgeLog

# ══════════════════════════════════════════════════════════════════
# Extracted handler functions
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
    $completed = Check-InflightResults
    if ($completed -gt 0 -and (Get-InflightCount) -eq 0) {
        $q = Read-Json -path $script:queueFile
        if ($q -and ($q.state -eq "running" -or $q.state -eq "blocked")) {
            Write-Text -path $script:queueFile -content (Get-IdleQueueJson)
            Log "[INFLIGHT] All commands completed — queue reset to idle"
        }
    }
}

function Invoke-HandleDedup {
    <#.SYNOPSIS Check content-hash dedup. Returns $true if dedup hit (command skipped).#>
    param([string]$CmdId, [string]$RawCmd)
    $hit = Get-ContentDedup $RawCmd
    if (-not $hit) { return $false }

    $ageMs = [int]((Get-Date) - $hit.timestamp).TotalMilliseconds
    Log "[$CmdId] CONTENT-HASH HIT: '$($RawCmd.Substring(0,[Math]::Min(80,$RawCmd.Length)))' = $($hit.cmd_id) (${ageMs}ms ago)"
    $cachedFile = Join-Path $script:baseDir "r_$($hit.cmd_id).json"
    if (Test-Path $cachedFile) {
        try {
            $cached = [System.IO.File]::ReadAllText($cachedFile, $script:utf8) | ConvertFrom-Json
            $cached.cmd_id = $CmdId
            $cached.duration_ms = $ageMs
            Write-Text -path (Join-Path $script:baseDir "r_${CmdId}.json") -content ($cached | ConvertTo-Json -Compress)
        } catch {
            Log "[$CmdId] CONTENT-HASH cache read failed — proceeding with execution"
            return $false
        }
    }
    Write-Text -path $script:queueFile -content (Get-IdleQueueJson)
    return $true
}

function Invoke-ApplyRules {
    <#.SYNOPSIS Apply rule engine transformations to a command.#>
    param([string]$Cmd, [string]$Type)
    if (Get-Command "Init-RuleEngine" -ErrorAction SilentlyContinue) {
        return Apply-Rules -Cmd $Cmd -Type $Type
    }
    return @{cmd=(Legacy-ApplyRules -cmd $Cmd -ctype $Type); type=$Type; applied=@()}
}

function Invoke-MetaCommand {
    <#.SYNOPSIS Handle __BRIDGE_RESTART__ and __BRIDGE_STOP__. Returns $true if handled.#>
    param([string]$Cmd, [string]$CmdId)
    if ($Cmd -eq "__BRIDGE_RESTART__") {
        Log "[$CmdId] BRIDGE RESTART — launching restarter"
        $restarterScript = Join-Path (Split-Path -Parent $script:watcherScriptPath) "restarter.ps1"
        if (Test-Path $restarterScript) {
            try {
                Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$restarterScript`"",
                    "-OldPID", [string]$PID,
                    "-WatcherPath", "`"$script:watcherScriptPath`"",
                    "-LogFile", "`"$script:logFile`""
                ) -PassThru | ForEach-Object { Log "[$CmdId] Restarter launched PID=$($_.Id)" }
            } catch { Log "[$CmdId] Failed to launch restarter: $_" }
        }
        Reset-QueueToIdle -Path $script:queueFile
        Write-CommandResult -Result (New-CommandResult -CmdId $CmdId -ExitCode 0 -Stdout "Bridge restarting...") -Directory $script:baseDir
        try { Remove-Item (Join-Path $script:baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
        exit 0
    }
    if ($Cmd -eq "__BRIDGE_STOP__") {
        Log "[$CmdId] BRIDGE STOP — exiting permanently"
        $script:inflight = @{}
        Reset-QueueToIdle -Path $script:queueFile
        Write-CommandResult -Result (New-CommandResult -CmdId $CmdId -ExitCode 0 -Stdout "Bridge stopped") -Directory $script:baseDir
        try { Remove-Item (Join-Path $script:baseDir ".watcher.lock") -Force -ErrorAction SilentlyContinue } catch {}
        exit 0
    }
    return $false
}

function Invoke-InlineExecution {
    <#.SYNOPSIS Handle __INLINE__ type — execute PowerShell directly in-process.#>
    param([string]$CmdId, [string]$RawCmd, [datetime]$StartTime)
    Log "[$CmdId] INLINE execution"
    $result = Invoke-ScriptBlockFastPath -Command $RawCmd -TimeoutSeconds 30
    $elapsed = [int]((Get-Date) - $StartTime).TotalMilliseconds

    $res = New-CommandResult -CmdId $CmdId -ExitCode $result.exit_code `
        -Stdout $result.stdout -Error $result.error -DurationMs $elapsed -FastPath $true
    Reset-QueueToIdle -Path $script:queueFile
    Write-CommandResult -Result $res -Directory $script:baseDir
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

    # Poll for result
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

    $res = New-CommandResult -CmdId $CmdId -ExitCode $userExit -Stdout $userOut `
        -Stderr $userErr -Error $userError -DurationMs ([int]((Get-Date) - $StartTime).TotalMilliseconds)
    Reset-QueueToIdle -Path $script:queueFile
    Write-CommandResult -Result $res -Directory $script:baseDir
    $script:inflight.Remove($CmdId)
    Add-ContentDedup -CmdText $Cmd -CmdId $CmdId
    Log "[$CmdId] USER result written (exit=$userExit)"
}

function Invoke-InprocessFallback {
    <#.SYNOPSIS Execute command in-process when no worker is available.#>
    param([string]$CmdId, [string]$RawCmd, [string]$Ctype, [int]$Timeout)

    $subT0 = Get-Date
    $progressFile = Join-Path $script:baseDir "r_${CmdId}_progress.json"

    # Use BridgeExecution module
    $result = Invoke-BridgeCommand -Command $RawCmd -Type $Ctype -TimeoutSeconds $Timeout -ProgressPath $progressFile

    $elapsed = [int]((Get-Date) - $subT0).TotalMilliseconds
    $res = New-CommandResult -CmdId $CmdId -ExitCode $result.exit_code `
        -Stdout $result.stdout -Stderr $result.stderr -Error $result.error `
        -DurationMs $elapsed -FastPath $result.fast_path
    Reset-QueueToIdle -Path $script:queueFile
    Write-CommandResult -Result $res -Directory $script:baseDir
    Add-ContentDedup -CmdText $RawCmd -CmdId $CmdId
    Log "  [$CmdId] result written (exit=$($result.exit_code), dur=${elapsed}ms, fast=$($result.fast_path))"
}

function Test-SelfUpgrade {
    <#.SYNOPSIS Check if watcher.ps1 has changed on disk and trigger graceful restart.#>
    $script:selfUpgradeCounter++
    if ($script:selfUpgradeCounter -ge $script:selfUpgradeCheckInterval) {
        $script:selfUpgradeCounter = 0
        try {
            $currentWrite = (Get-Item $script:watcherScriptPath).LastWriteTime
            if ($currentWrite -gt $script:watcherScriptLastWrite) {
                Log "[SELF-UPGRADE] watcher.ps1 changed — initiating graceful restart"
                Write-Text -path $script:restartFlagFile -content ((Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"))
                $restartCmd = @{
                    state = "pending"
                    cmd_id = "__SELF_UPGRADE_$(Get-Date -Format 'yyyyMMddHHmmss')__"
                    type = "__BRIDGE_RESTART__"
                    command = ""
                    timeout = 10
                } | ConvertTo-Json -Compress
                Write-Text -path $script:queueFile -content $restartCmd
            }
        } catch { Log "[SELF-UPGRADE] Check failed: $_" }
    }
}


# ══════════════════════════════════════════════════════════════════
# REFACTORED MAIN LOOP (replaces L536-919)
# ══════════════════════════════════════════════════════════════════
<#
while ($true) {
    try {
        # 1. Heartbeat
        Write-Heartbeat -Path $script:heartbeatFile

        # 2. Wait for queue change
        $script:queueWatcher.WaitForChanged([System.IO.WatcherChangeTypes]::Changed, 50) | Out-Null
        $queue = Read-Json -path $script:queueFile

        # 3. Periodic housekeeping (~60s)
        $script:housekeepCounter++
        Invoke-Housekeeping -Counter $script:housekeepCounter

        # 4. Check inflight results
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
            $ruleResult = Invoke-ApplyRules -Cmd $rawCmd -Type $ctype
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

            # 5g. Named Pipe dispatch
            $pipeDispatched = $false
            $worker = Dispatch-ToWorker -cid $cid -ctype $ctype -cmd $cmd -timeout $origTimeout
            if ($worker) {
                Add-Inflight -CmdId $cid -Worker $worker -Ctype $ctype -Timeout $origTimeout
                $pipeDispatched = $true
                Reset-QueueToIdle -Path $script:queueFile
                Log "[$cid] V21 ASYNC-DISPATCH to $($worker.id)"
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
#>
