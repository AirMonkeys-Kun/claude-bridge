# ══════════════════════════════════════════════════════════════════
# Rule engine wrapper — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Invoke-ApplyRules {
    <#.SYNOPSIS Apply rule engine transformations to a command.#>
    param([string]$Cmd, [string]$Type, [string]$CmdId)
    try {
        $result = Apply-Rules -Cmd $Cmd -Type $Type
        if ($result.applied -and $result.applied.Count -gt 0) {
            Log "[$CmdId] RULES applied: $($result.applied -join ',')"
        }
        return $result
    } catch {
        Log "[$CmdId] Apply-Rules failed: $($_.Exception.Message) — passthrough"
        return @{cmd=$Cmd; type=$Type; applied=@()}
    }
}
