<#
.SYNOPSIS
    BridgeExecution — command execution functions for Claude Bridge.
.DESCRIPTION
    Provides the two execution paths used across all workers:
    - ScriptBlock fast path (~10ms, in-process)
    - Subprocess execution (powershell/cmd/wsl, with timeout and progress)
    Eliminates duplication between watcher.ps1, worker_generic.ps1, and worker_template.ps1.
#>

using module BridgeCommon

# ══════════════════════════════════════════════════════════════════
# Command type normalization
# ══════════════════════════════════════════════════════════════════

function Resolve-CommandType {
    <#
    .SYNOPSIS
        Normalize command type aliases to canonical names.
    #>
    [CmdletBinding()]
    param([string]$Type)
    switch ($Type) {
        { $_ -in @("i", "__INLINE__") } { return "inline" }
        { $_ -in @("c", "cmd") }        { return "cmd" }
        { $_ -in @("w", "wsl") }        { return "wsl" }
        { $_ -in @("p", "powershell") } { return "powershell" }
        default                          { return "powershell" }
    }
}

# ══════════════════════════════════════════════════════════════════
# ScriptBlock fast path
# ══════════════════════════════════════════════════════════════════

function Invoke-ScriptBlockFastPath {
    <#
    .SYNOPSIS
        Execute a command as a PowerShell ScriptBlock in a runspace.
        ~10ms overhead vs ~150ms for spawning powershell.exe.
    .OUTPUTS
        Hashtable with stdout, exit_code, error, duration_ms.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSeconds = 30
    )

    $stdout = ""
    $errorMsg = ""
    $exitCode = -1
    $t0 = Get-Date

    try {
        $sb = [ScriptBlock]::Create($Command)
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($sb)

        $async = $ps.BeginInvoke()
        if ($async.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
            $result = $ps.EndInvoke($async)
            if ($result -ne $null) { $stdout = ($result | Out-String).Trim() }
            $exitCode = 0
        } else {
            $ps.Stop()
            $errorMsg = "TIMEOUT after ${TimeoutSeconds}s"
            $stdout = "[TIMEOUT]"
        }
        $ps.Dispose()
    } catch {
        $errorMsg = $_.Exception.Message
    }

    $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
    return @{
        stdout      = $stdout
        exit_code   = $exitCode
        error       = $errorMsg
        duration_ms = $elapsed
    }
}

# ══════════════════════════════════════════════════════════════════
# Subprocess execution
# ══════════════════════════════════════════════════════════════════

function Invoke-Subprocess {
    <#
    .SYNOPSIS
        Execute a command in a subprocess with timeout and optional progress reporting.
    .PARAMETER Type
        Canonical type: "powershell", "cmd", "wsl", or "inline".
    .PARAMETER Command
        The command string to execute.
    .PARAMETER TimeoutSeconds
        Maximum execution time.
    .PARAMETER ProgressPath
        Optional path for progress flush files.
    .OUTPUTS
        Hashtable with stdout, stderr, exit_code, error, duration_ms.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Type,
        [int]$TimeoutSeconds = 30,
        [string]$ProgressPath
    )

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $stdout = ""
    $stderr = ""
    $errorMsg = ""
    $exitCode = -1
    $t0 = Get-Date

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8

        switch ($Type) {
            "cmd" {
                $psi.FileName = "cmd.exe"
                $psi.Arguments = "/c $Command"
            }
            "wsl" {
                $psi.FileName = "cmd.exe"
                $psi.Arguments = "/c wsl.exe -e bash -c '$Command'"
            }
            default {
                # PowerShell — Base64 encoded to avoid quoting issues
                $psi.FileName = "powershell.exe"
                $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
            }
        }

        $process = [System.Diagnostics.Process]::Start($psi)

        # Progress flush loop (read stdout in chunks, write progress)
        $stdoutDone = $false
        $stderrDone = $false
        $progressMs = 0

        while (-not $process.WaitForExit(1000)) {
            $progressMs += 1000
            # Progress flush for long-running commands
            if ($ProgressPath -and $progressMs -ge 5000) {
                $progressMs = 0
                try {
                    $elapsed = [int]((Get-Date) - $t0).TotalSeconds
                    $pf = @{
                        state = "running"
                        cmd_id = ""
                        elapsed_seconds = $elapsed
                        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                    }
                    $ppath = $ProgressPath
                    [System.IO.File]::WriteAllText($ppath, ($pf | ConvertTo-Json -Compress), $utf8)
                } catch { }
            }

            if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $t0).TotalSeconds -gt ($TimeoutSeconds + 2)) {
                $process.Kill()
                $stdout = "[TIMEOUT]"
                $errorMsg = "TIMEOUT"
                break
            }
        }

        if ($stdout -ne "[TIMEOUT]") {
            Start-Sleep -Milliseconds 150
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            # Strip null bytes
            $stdout = $stdout -replace "`0", ""
            $stderr = $stderr -replace "`0", ""
            $exitCode = $process.ExitCode
        }
        $process.Dispose()
    } catch {
        $errorMsg = $_.Exception.Message
    }

    $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
    return @{
        stdout      = $stdout
        stderr      = $stderr
        exit_code   = $exitCode
        error       = $errorMsg
        duration_ms = $elapsed
    }
}

# ══════════════════════════════════════════════════════════════════
# Unified command execution (auto-selects fast path vs subprocess)
# ══════════════════════════════════════════════════════════════════

function Invoke-BridgeCommand {
    <#
    .SYNOPSIS
        Execute a command, choosing the best execution path automatically.
    .PARAMETER Command
        The command string.
    .PARAMETER Type
        Command type (will be normalized via Resolve-CommandType).
    .PARAMETER TimeoutSeconds
        Maximum execution time (default 30s).
    .PARAMETER ProgressPath
        Optional progress file path for long subprocess commands.
    .PARAMETER WorkerDir
        Worker directory (for progress file path generation).
    .OUTPUTS
        A standardized result hashtable suitable for New-CommandResult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Type = "powershell",
        [int]$TimeoutSeconds = 30,
        [string]$ProgressPath = "",
        [string]$WorkerDir = ""
    )

    $canonicalType = Resolve-CommandType -Type $Type
    $t0 = Get-Date

    # Progress path: if WorkerDir given, use r_{cmd_id}_progress.json
    if ($WorkerDir -and -not $ProgressPath) {
        # Caller should set this — we don't know cmd_id here
    }

    if ($canonicalType -eq "inline") {
        # ScriptBlock fast path
        $result = Invoke-ScriptBlockFastPath -Command $Command -TimeoutSeconds $TimeoutSeconds
        return @{
            exit_code   = $result.exit_code
            stdout      = $result.stdout
            stderr      = ""
            error       = $result.error
            duration_ms = $result.duration_ms
            fast_path   = $true
        }
    } else {
        # Subprocess execution
        $result = Invoke-Subprocess -Command $Command -Type $canonicalType `
            -TimeoutSeconds $TimeoutSeconds -ProgressPath $ProgressPath
        return @{
            exit_code   = $result.exit_code
            stdout      = $result.stdout
            stderr      = $result.stderr
            error       = $result.error
            duration_ms = $result.duration_ms
            fast_path   = $false
        }
    }
}

# ── Export ──
Export-ModuleMember -Function @(
    'Resolve-CommandType',
    'Invoke-ScriptBlockFastPath',
    'Invoke-Subprocess',
    'Invoke-BridgeCommand'
)
