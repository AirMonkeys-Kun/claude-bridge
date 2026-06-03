#Requires -Version 5.0
<#
error-learner.ps1 — error pattern detection + auto-rule generation (V18)
  From watcher V5: logs execution errors, detects patterns, suggests fixes.
  Exports:        Log-Error, Generate-Rules
#>

. "$PSScriptRoot\bridge-core.ps1"

# ── Log an execution error for pattern analysis ───────────────────────
function Log-Error {
    param(
        [string]$CmdId,
        [string]$Type,
        [string]$Command,
        [int]$ExitCode,
        [string]$Stdout,
        [string]$Stderr,
        [int]$DurationMs
    )

    $needLearning = $false
    $issueDesc = ""

    # Detect error patterns
    if ($ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($Stderr)) {
        $needLearning = $true
        if ($Stderr -match "not recognized|not a cmdlet|unknown command") {
            $issueDesc = "command_not_found_or_wrong_shell"
        } elseif ($Stderr -match "access denied|permission denied") {
            $issueDesc = "permission_denied"
        } elseif ($Stderr -match "timeout|timed out") {
            $issueDesc = "timeout"
        } else {
            $issueDesc = "exit_code_non_zero_with_stderr"
        }
    } elseif ($ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($Stdout) -and -not [string]::IsNullOrWhiteSpace($Stderr)) {
        $needLearning = $true
        $issueDesc = "stderr_with_success_exit"
    }

    if (-not $needLearning) { return }

    # Build error entry
    $entry = @{
        cmd_id           = $CmdId
        timestamp        = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        type             = $Type
        command_summary  = if ($Command.Length -gt 120) { $Command.Substring(0, 120) + "..." } else { $Command }
        exit_code        = $ExitCode
        issue            = $issueDesc
        stderr_snippet   = if ($Stderr.Length -gt 200) { $Stderr.Substring(0, 200) } else { $Stderr }
        duration_ms      = $DurationMs
    }

    # Write to error history
    try {
        $existing = @{version="2.0"; errors=@()}
        if (Test-Path $script:errorHistoryFile) {
            $existingText = [System.IO.File]::ReadAllText($script:errorHistoryFile, $script:utf8)
            if (-not [string]::IsNullOrWhiteSpace($existingText)) {
                try { $existing = ($existingText | ConvertFrom-Json) } catch {}
            }
        }

        # Ensure errors array exists
        if (-not $existing.errors) { $existing.errors = @() }
        $existing.errors += $entry

        # Keep last 100
        if ($existing.errors.Count -gt 100) {
            $existing.errors = $existing.errors | Select-Object -Last 100
        }

        $existing.last_updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $existing.total_errors_logged = $existing.errors.Count

        $json = ($existing | ConvertTo-Json -Depth 4 -Compress)
        [System.IO.File]::WriteAllText($script:errorHistoryFile, $json, $script:utf8)
        Log "[LEARN] Error logged: $CmdId → $issueDesc"
    } catch {
        Log "[LEARN] Failed to write error history: $_"
    }
}

# ── Auto-generate rules from error patterns ───────────────────────────
function Generate-Rules {
    # Placeholder — integrates with rule_engine.ps1 when available
    # Currently, the RuleEngine in cluster/rule_engine.ps1 handles auto-generation
    $newRules = @()
    Log "[LEARN] Generate-Rules called — no new rules generated (rule engine handles auto-gen)"
    return $newRules
}

Log "error-learner loaded"
