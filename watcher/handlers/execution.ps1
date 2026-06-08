# ══════════════════════════════════════════════════════════════════
# Command execution handlers — extracted from watcher.ps1 V22
# ══════════════════════════════════════════════════════════════════

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
                $userOut = $ur.stdout; $userErr = $ur.stderr; $userExit = $ur.exit_code; $userError = $ur.error
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

function Invoke-MaintenanceCommand {
    <#.SYNOPSIS Handle 'maintenance' type — set/clear/check maintenance lock in-process.#>
    param([string]$CmdId, [string]$RawCmd, [datetime]$StartTime)

    $lockPath = Join-Path (Split-Path $script:baseDir -Parent) "watcher\.maintenance.lock"
    $action = ($RawCmd -replace '^\s*|\s*$', '').ToLower()
    $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""

    if ($action -eq "enter" -or $action -eq "lock") {
        $reason = if ($RawCmd -match 'reason=(.+)') { $Matches[1] } else { "manual" }
        $ttl = if ($RawCmd -match 'ttl=(\d+)') { [int]$Matches[1] } else { 1800 }
        $lockObj = @{
            reason = $reason; started_at = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            ttl = $ttl; pid = $pid
        }
        try {
            $lockObj | ConvertTo-Json -Compress | Set-Content -Path $lockPath -NoNewline -Encoding UTF8
            $stdout = "Maintenance lock SET (reason=$reason, ttl=${ttl}s)"
            $exitCode = 0
        } catch {
            $stderr = "Failed to set lock: $_"
            $errorMsg = $stderr
        }
    } elseif ($action -eq "exit" -or $action -eq "unlock" -or $action -eq "clear") {
        try {
            if (Test-Path $lockPath) { Remove-Item $lockPath -Force }
            $stdout = "Maintenance lock CLEARED"
            $exitCode = 0
        } catch {
            $stderr = "Failed to clear lock: $_"
            $errorMsg = $stderr
        }
    } else {  # status / check
        if (Test-Path $lockPath) {
            try {
                $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $started = [DateTime]::ParseExact($lock.started_at, "yyyy-MM-dd HH:mm:ss", $null)
                $age = [int]((Get-Date) - $started).TotalSeconds
                $ttl = if ($lock.ttl) { $lock.ttl } else { 1800 }
                if ($age -ge $ttl) {
                    $stdout = "Maintenance lock EXPIRED (age=${age}s >= ttl=${ttl}s) — auto-cleared"
                    Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
                } else {
                    $stdout = "Maintenance lock ACTIVE (age=${age}s, ttl=${ttl}s, reason=$($lock.reason))"
                }
            } catch {
                $stdout = "Maintenance lock CORRUPT — removing"
                Remove-Item $lockPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            $stdout = "Maintenance lock: not set — recovery layers fully active"
        }
        $exitCode = 0
    }

    $result = New-CommandResult -CmdId $CmdId -ExitCode $exitCode `
        -Stdout $stdout -Stderr $stderr -Error $errorMsg `
        -DurationMs ([int]((Get-Date) - $StartTime).TotalMilliseconds)
    if ($errorMsg) { $result.state = "error" }
    Reset-QueueToIdle -Path $script:queueFile
    Write-CommandResult -Result $result -Directory $script:baseDir
    $script:inflight.Remove($CmdId)
    Log "[$CmdId] MAINTENANCE command: $stdout"
}

function Invoke-InprocessFallback {
    <#.SYNOPSIS Execute command in-process when no worker is available.#>
    param([string]$CmdId, [string]$RawCmd, [string]$Ctype, [int]$Timeout)

    # ── Maintenance type: handled directly, not executed as PowerShell ──
    if ($Ctype -eq "maintenance") {
        Invoke-MaintenanceCommand -CmdId $CmdId -RawCmd $RawCmd -StartTime (Get-Date)
        return
    }

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
