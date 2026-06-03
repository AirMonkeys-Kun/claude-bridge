#Requires -Version 5.0
<#
command-executor.ps1 — script execution with safety fallback (V18)
  Strategy:  ScriptBlock in-process first (~10ms), subprocess on failure (~150ms).
  Mirrors:   worker.ps1 V4 Smart execution + watcher.ps1 V17 fast path.
  Exports:   Invoke-CommandSafe
#>

. "$PSScriptRoot\bridge-core.ps1"

# ── Safe command execution ────────────────────────────────────────────
# Returns: @{exitCode, stdout, stderr, error, durationMs, wasFastPath}
function Invoke-CommandSafe {
    param(
        [string]$Command,
        [string]$Type,          # powershell, powershell_text, inline, cmd
        [int]$TimeoutSec = 30,
        [string]$CmdId = ""     # for logging
    )

    $t0 = Get-Date
    $result = @{
        exitCode    = -1
        stdout      = ""
        stderr      = ""
        error       = ""
        durationMs  = 0
        wasFastPath = $false
    }

    $normalizedType = $Type.ToLower()

    # ── Fast path: Runspace-wrapped ScriptBlock with timeout (V18.2) ────
    if ($normalizedType -eq "powershell" -or $normalizedType -eq "powershell_text" -or $normalizedType -eq "inline" -or $normalizedType -eq "p" -or $normalizedType -eq "i") {
        $sbFastFailed = $false
        try {
            # Strip 'exit N' / 'exit' — would kill the bridge host process
            $sbCmd = $Command -replace '\bexit\s+\d+\s*;?\s*$', '' -replace '\bexit\s*;?\s*$', ''

            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.AddScript({
                param($Cmd)
                $ErrorActionPreference = 'Continue'
                & ([ScriptBlock]::Create($Cmd)) 2>&1
            }).AddArgument($sbCmd)

            $handle = $ps.BeginInvoke()
            $sbTimeoutMs = [Math]::Max(1000, ($TimeoutSec * 1000))
            if ($handle.AsyncWaitHandle.WaitOne($sbTimeoutMs)) {
                $sbResult = $ps.EndInvoke($handle)
                $result.stdout = if ($sbResult -ne $null) { ($sbResult | Out-String).Trim() } else { "" }
                $result.exitCode = 0
                $result.wasFastPath = $true
                $result.durationMs = [int]((Get-Date) - $t0).TotalMilliseconds
                Log "[$CmdId] V18.2 RUNSPACE fast-path: $($result.durationMs)ms"
                $ps.Dispose()
                return $result
            } else {
                $ps.Stop()
                $sbFastFailed = $true
                Log "[$CmdId] V18.2 RUNSPACE TIMEOUT after ${TimeoutSec}s — falling back to subprocess"
            }
            $ps.Dispose()

        } catch {
            $sbFastFailed = $true
            $sbError = $_.Exception.Message
            Log "[$CmdId] V18.2 Runspace failed ($sbError) — falling back to subprocess"
        }
    }

    # ── Slow path: subprocess (cmd, or ScriptBlock failure fallback) ─────
    if ($script:executor_psiAssembly -eq $null) {
        # Cache ProcessStartInfo type for speed
        $script:executor_psiAssembly = [System.Diagnostics.ProcessStartInfo].Assembly
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo

        if ($normalizedType -eq "cmd" -or $normalizedType -eq "c") {
            $psi.FileName = "cmd.exe"
            $psi.Arguments = "/c $Command"
        } elseif ($normalizedType -eq "powershell" -or $normalizedType -eq "p") {
            $psi.FileName = "powershell.exe"
            $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Command))
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
        } else {
            # powershell_text, inline that failed, or anything else
            $psi.FileName = "powershell.exe"
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$($Command -replace '\"', '\"')`""
        }

        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = $script:utf8
        $psi.StandardErrorEncoding  = $script:utf8

        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p) { throw "Process.Start returned null" }

        # ReadToEndAsync for 100% capture
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        # Wait with timeout
        $timedOut = $false
        if ($p.WaitForExit($TimeoutSec * 1000)) {
            $result.exitCode = $p.ExitCode
            $result.stdout = $outTask.Result
            $result.stderr = $errTask.Result
        } else {
            $timedOut = $true
            try { $p.Kill() } catch {}
            try { $result.stdout = $outTask.Result } catch {}
            try { $result.stderr = $errTask.Result } catch {}
            $result.exitCode = -1
            $result.error = "TIMEOUT after ${TimeoutSec}s"
            if ([string]::IsNullOrEmpty($result.stdout)) {
                $result.stdout = "[TIMEOUT after ${TimeoutSec}s]"
            }
        }

        $p.Dispose()
        $result.durationMs = [int]((Get-Date) - $t0).TotalMilliseconds
        $mode = if ($timedOut) { "TIMEOUT" } else { "subprocess" }
        Log "[$CmdId] $mode exit=$($result.exitCode) out=$($result.stdout.Length)chars dur=$($result.durationMs)ms"

    } catch {
        $result.error = $_.Exception.Message
        $result.durationMs = [int]((Get-Date) - $t0).TotalMilliseconds
        Log "[$CmdId] EXCEPTION: $($result.error)"
    }

    return $result
}

Log "command-executor loaded"
