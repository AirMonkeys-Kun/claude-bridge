#Requires -Version 5.0
# Claude Bridge V5 — Shared Rule Engine
# Apply-Rules / Filter-CLIXML / Log-ExecutionError / Generate-Rules

# -- Global Config --
$script:RE_baseDir = $null
$script:RE_rulesFile = $null
$script:RE_errorHistoryFile = $null
$script:RE_rulesCache = $null
$script:RE_cmdCounter = 0
$script:RE_lastGenerateCheck = 0
$script:RE_generateInterval = 20
$script:RE_utf8 = [System.Text.UTF8Encoding]::new($false)

function RE-Log {
    param([string]$Source, [string]$Msg)
    try {
        $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        $logPath = Join-Path $script:RE_baseDir "cluster\rule_engine.log"
        [System.IO.File]::AppendAllText($logPath, "$t | [$Source] $Msg`r`n", $script:RE_utf8)
    } catch {}
}

function Init-RuleEngine {
    param([string]$BridgeBase)
    $script:RE_baseDir = $BridgeBase
    $script:RE_rulesFile = Join-Path $BridgeBase "watcher\bridge_rules.json"
    $script:RE_errorHistoryFile = Join-Path $BridgeBase "watcher\error_history.json"
    $script:RE_rulesCache = $null
    $script:RE_cmdCounter = 0
    $script:RE_lastGenerateCheck = 0
    RE-Log "ENGINE" "Init OK base=$BridgeBase"
    return $true
}

function RE-ReadFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try { return [System.IO.File]::ReadAllText($Path, $script:RE_utf8) }
        catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 50 }
    }
}

function RE-WriteFile {
    param([string]$Path, [string]$Content)
    for ($i = 0; $i -lt 3; $i++) {
        try { [System.IO.File]::WriteAllText($Path, $Content, $script:RE_utf8); return $true }
        catch { if ($i -eq 2) { return $false }; Start-Sleep -Milliseconds 50 }
    }
}

# ═══════════════════════════════════════════════
# Filter-CLIXML
# ═══════════════════════════════════════════════
function Filter-CLIXML {
    param([string]$StderrText)
    if ([string]::IsNullOrWhiteSpace($StderrText)) { return "" }
    $lines = $StderrText -split "`r`n|`n"
    $clean = @()
    $inClixml = $false
    foreach ($line in $lines) {
        if ($line -match '^#< CLIXML') { $inClixml = $true; continue }
        if ($inClixml) {
            if ($line -match '</Objs>') { $inClixml = $false; continue }
            if ($line -notmatch '<') { $inClixml = $false }
            else { continue }
        }
        if (-not $inClixml -and -not [string]::IsNullOrWhiteSpace($line)) {
            $clean += $line
        }
    }
    return ($clean -join "`r`n")
}

# ═══════════════════════════════════════════════
# Get-Rules / Save-Rules
# ═══════════════════════════════════════════════
function Get-Rules {
    param([switch]$ForceReload)
    $script:RE_cmdCounter++
    if ($ForceReload -or $null -eq $script:RE_rulesCache -or ($script:RE_cmdCounter % 10 -eq 1)) {
        $text = RE-ReadFile $script:RE_rulesFile
        if ($text) {
            try {
                $parsed = ($text | ConvertFrom-Json)
                $script:RE_rulesCache = $parsed.rules
                RE-Log "RULES" "Loaded $($script:RE_rulesCache.Count) rules"
            } catch { if (-not $script:RE_rulesCache) { $script:RE_rulesCache = @() } }
        } else { if (-not $script:RE_rulesCache) { $script:RE_rulesCache = @() } }
    }
    return $script:RE_rulesCache
}

function Save-Rules {
    param([array]$Rules)
    $data = @{version="2.0"; last_updated=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); rules=$Rules}
    $json = $data | ConvertTo-Json -Depth 4
    if (RE-WriteFile $script:RE_rulesFile $json) {
        $script:RE_rulesCache = $Rules
        RE-Log "RULES" "Saved $($Rules.Count) rules"
        return $true
    }
    return $false
}

# ═══════════════════════════════════════════════
# Apply-Rules
# ═══════════════════════════════════════════════
function Apply-Rules {
    param([string]$Cmd, [string]$Type)
    $rules = Get-Rules
    if (-not $rules -or $rules.Count -eq 0) { return @{cmd=$Cmd; type=$Type; applied=@()} }
    $modified = $Cmd
    $newType = $Type
    $applied = @()
    foreach ($rule in $rules) {
        if ($rule.is_template -or $rule.disabled) { continue }
        $triggers = $rule.triggers
        if (-not $triggers) { continue }
        $typeMatch = $false
        if ($triggers.type -eq "any") { $typeMatch = $true }
        elseif ($triggers.type -eq $newType) { $typeMatch = $true }
        elseif ($triggers.type -eq "cmd" -and ($newType -eq "c" -or $newType -eq "cmd")) { $typeMatch = $true }
        elseif ($triggers.type -eq "powershell" -and ($newType -eq "p" -or $newType -eq "powershell")) { $typeMatch = $true }
        elseif ($triggers.type -eq "wsl" -and ($newType -eq "w" -or $newType -eq "wsl")) { $typeMatch = $true }
        elseif ($triggers.type -eq "inline" -and ($newType -eq "i" -or $newType -eq "__INLINE__")) { $typeMatch = $true }
        if (-not $typeMatch) { continue }
        if ($triggers.command_contains -and $modified -notmatch [regex]::Escape($triggers.command_contains)) { continue }
        if ($triggers.pattern_in_command -and $modified -notmatch $triggers.pattern_in_command) { continue }
        $fix = $rule.fix
        $appliedThis = $false
        if ($fix.action -eq "escape" -and $fix.find -and $fix.replace_with) {
            $modified = $modified.Replace($fix.find, $fix.replace_with)
            $appliedThis = $true
        } elseif ($fix.action -eq "wrap_single_quotes") {
            if ($modified -match 'wsl -e bash -c "(.+)"') {
                $inner = $matches[1]
                $modified = $modified.Replace('wsl -e bash -c "' + $inner + '"', "wsl -e bash -c '$inner'")
                $appliedThis = $true
            }
        } elseif ($fix.action -eq "change_type" -and $fix.to_type -and $newType -ne $fix.to_type) {
            $newType = $fix.to_type
            $appliedThis = $true
        } elseif ($fix.action -eq "regex_replace" -and $fix.pattern -and $fix.replacement) {
            $modified = $modified -replace $fix.pattern, $fix.replacement
            $appliedThis = $true
        } elseif ($fix.action -eq "prepend" -and $fix.text) {
            $modified = $fix.text + $modified
            $appliedThis = $true
        } elseif ($fix.action -eq "suffix" -and $fix.text) {
            $modified = $modified + $fix.text
            $appliedThis = $true
        }
        if ($appliedThis) {
            $applied += $rule.id
            $rule.hits = [int]$rule.hits + 1
            RE-Log "RULE" "Applied $($rule.id) to '$($modified.Substring(0,[Math]::Min(80,$modified.Length)))'"
        }
    }
    if ($applied.Count -gt 0) { Save-Rules $rules }
    return @{cmd=$modified; type=$newType; applied=$applied}
}

# ═══════════════════════════════════════════════
# Log-ExecutionError
# ═══════════════════════════════════════════════
function Log-ExecutionError {
    param([string]$CmdId, [string]$Type, [string]$Command, [int]$ExitCode, [string]$StdoutText, [string]$StderrText, [int]$DurationMs)
    $cleanStderr = Filter-CLIXML $StderrText
    $hasRealError = $false
    $issueDesc = ""
    if ($ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($cleanStderr)) {
        $hasRealError = $true
        if ($cleanStderr -match "not recognized|not a cmdlet|unknown command|is not recognized") { $issueDesc = "command_not_found_or_wrong_shell" }
        elseif ($cleanStderr -match "access denied|permission denied|denied|Access is denied") { $issueDesc = "permission_denied" }
        elseif ($cleanStderr -match "TerminatorExpected|String is missing|ParserError|ParseException") { $issueDesc = "syntax_error_quoting" }
        elseif ($cleanStderr -match "MethodNotFoundException|method_not_found") { $issueDesc = "method_not_found" }
        elseif ($cleanStderr -match "connection.*refused|connect.*failed") { $issueDesc = "connection_failed" }
        elseif ($cleanStderr -match "FileNotFoundException|No such file") { $issueDesc = "file_not_found" }
        else { $issueDesc = "exit_code_non_zero_with_stderr" }
    } elseif ($ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($cleanStderr)) {
        $hasRealError = $true
        $issueDesc = "exit_code_non_zero_clixml_only"
    } elseif ($ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($cleanStderr)) {
        $hasRealError = $true
        $issueDesc = "stderr_with_success_exit"
    }
    if (-not $hasRealError) { return $null }
    $patternSignatures = @()
    if ($Type -eq "cmd" -or $Type -eq "c") {
        if ($Command -match '&&') { $patternSignatures += "ampersand_in_cmd" }
        if ($Command -match '\|') { $patternSignatures += "pipe_in_cmd" }
    }
    if ($Type -eq "powershell" -or $Type -eq "p" -or $Type -eq "wsl" -or $Type -eq "w") {
        if ($Command -match 'wsl' -and $Command -match ';') { $patternSignatures += "semicolon_in_ps_wsl" }
        if ($Command -match 'wsl' -and $Command -match '\|') { $patternSignatures += "pipe_in_ps_wsl" }
    }
    $entry = @{
        cmd_id=$CmdId; timestamp=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); type=$Type
        command_summary=$(if ($Command.Length -gt 120) { $Command.Substring(0, 120) + "..." } else { $Command })
        exit_code=$ExitCode; issue=$issueDesc; duration_ms=$DurationMs
        patterns=$patternSignatures
        stderr_snippet=$(if ($cleanStderr.Length -gt 300) { $cleanStderr.Substring(0, 300) } else { $cleanStderr })
        clixml_stripped=$($StderrText.Length -gt 0 -and $cleanStderr.Length -eq 0)
        auto_detected=$true
    }
    try {
        $ehText = RE-ReadFile $script:RE_errorHistoryFile
        $existing = @{version="2.0"; errors=@(); auto_generated_rules=0}
        if ($ehText) { try { $existing = ($ehText | ConvertFrom-Json) } catch {} }
        $existing.errors += $entry
        $existing.total_errors_logged = $existing.errors.Count
        $existing.last_updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        if ($existing.errors.Count -gt 200) { $existing.errors = $existing.errors | Select-Object -Last 200 }
        RE-WriteFile $script:RE_errorHistoryFile ($existing | ConvertTo-Json -Depth 4 -Compress)
        RE-Log "LEARN" "Logged: $CmdId -> $issueDesc [$(($patternSignatures | ForEach-Object { $_ }) -join ',')]"
    } catch { RE-Log "LEARN" "Write failed: $_" }
    return $entry
}

# ═══════════════════════════════════════════════
# Generate-Rules
# ═══════════════════════════════════════════════
function Generate-Rules {
    param([switch]$Force)
    $script:RE_cmdCounter++
    if (-not $Force -and ($script:RE_cmdCounter - $script:RE_lastGenerateCheck -lt $script:RE_generateInterval)) { return @() }
    $script:RE_lastGenerateCheck = $script:RE_cmdCounter
    $text = RE-ReadFile $script:RE_errorHistoryFile
    if (-not $text) { return @() }
    $history = $null; try { $history = ($text | ConvertFrom-Json) } catch { return @() }
    if (-not $history -or -not $history.errors -or $history.errors.Count -lt 3) { return @() }
    $errors = $history.errors
    $autoGenCount = [int]$history.auto_generated_rules
    $rules = Get-Rules -ForceReload
    $existingRuleIds = @{}; foreach ($r in $rules) { $existingRuleIds[$r.id] = $true }
    $candidates = @()
    $clixmlCount = ($errors | Where-Object { $_.clixml_stripped -eq $true }).Count
    if ($clixmlCount -ge 10 -and -not $existingRuleIds.ContainsKey("clixml-stderr-filter")) {
        $candidates += @{id="clixml-stderr-filter"; description="Auto-filter CLIXML stderr noise"; triggers=@{type="any"}; fix=@{action="clixml_filter"}; confidence=[Math]::Min(100,$clixmlCount*5); hits=0; auto_generated=$true; generation_source="clixml $clixmlCount times"; created=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
    }
    $ampersandErrors = $errors | Where-Object { $_.patterns -contains "ampersand_in_cmd" -or ($_.type -in @("cmd","c") -and $_.command_summary -match '&&') }
    if ($ampersandErrors.Count -ge 1 -and -not $existingRuleIds.ContainsKey("auto-cmd-escape-ampersand")) {
        $candidates += @{id="auto-cmd-escape-ampersand"; description="Escape && in cmd mode"; triggers=@{type="cmd"; pattern_in_command="&&"}; fix=@{action="escape"; find="&&"; replace_with="^&^&"}; confidence=[Math]::Min(100,$ampersandErrors.Count*30); hits=0; auto_generated=$true; generation_source="ampersand $($ampersandErrors.Count) times"; created=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
    }
    $semicolonWslErrors = $errors | Where-Object { $_.patterns -contains "semicolon_in_ps_wsl" -or ($_.patterns -contains "semicolon_in_cmd" -and $_.command_summary -match "wsl") }
    if ($semicolonWslErrors.Count -ge 1 -and -not $existingRuleIds.ContainsKey("auto-pswsl-semicolon-quote")) {
        $candidates += @{id="auto-pswsl-semicolon-quote"; description="Single-quote bash -c for WSL"; triggers=@{type="powershell"; command_contains="wsl -e bash -c"; pattern_in_command=";"}; fix=@{action="wrap_single_quotes"}; confidence=[Math]::Min(100,$semicolonWslErrors.Count*30); hits=0; auto_generated=$true; generation_source="semicolon $($semicolonWslErrors.Count) times"; created=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
    }
    $permErrors = $errors | Where-Object { $_.issue -eq "permission_denied" }
    if ($permErrors.Count -ge 3 -and -not $existingRuleIds.ContainsKey("auto-elevation-required")) {
        $candidates += @{id="auto-elevation-required"; description="Command needs elevation"; triggers=@{type="any"; error_in_stderr="access denied"}; fix=@{action="prepend"; text=""}; confidence=[Math]::Min(100,$permErrors.Count*20); hits=0; auto_generated=$true; generation_source="perm_denied $($permErrors.Count) times"; created=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
    }
    $toAdd = @()
    foreach ($cand in $candidates) {
        $cand.test_results = Test-RuleAgainstHistory -Rule $cand -Errors $errors
        if ($cand.test_results.passed) {
            $cand.confidence = [Math]::Min(100, $cand.confidence + $cand.test_results.bonus)
            if ($cand.confidence -ge 50) { $cand.active = $true; RE-Log "GEN" "ACTIVATED: $($cand.id) conf=$($cand.confidence)" }
            else { $cand.active = $false; RE-Log "GEN" "CANDIDATE: $($cand.id) conf=$($cand.confidence) (low)" }
            $toAdd += $cand
        } else { RE-Log "GEN" "SKIPPED: $($cand.id) - $($cand.test_results.reason)" }
    }
    if ($toAdd.Count -gt 0) {
        $rules += $toAdd; Save-Rules $rules
        try {
            $hText = RE-ReadFile $script:RE_errorHistoryFile
            if ($hText) { $hData = ($hText | ConvertFrom-Json); $hData.auto_generated_rules = [int]$hData.auto_generated_rules + $toAdd.Count; $hData.last_updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); RE-WriteFile $script:RE_errorHistoryFile ($hData | ConvertTo-Json -Depth 4 -Compress) }
        } catch {}
        RE-Log "GEN" "Generated $($toAdd.Count) new rules (total auto-gen: $($autoGenCount + $toAdd.Count))"
    }
    return $toAdd
}

# ═══════════════════════════════════════════════
# Test-RuleAgainstHistory
# ═══════════════════════════════════════════════
function Test-RuleAgainstHistory {
    param([object]$Rule, [array]$Errors)
    $result = @{passed=$false; reason=""; matched=0; falsePositives=0; bonus=0}
    if (-not $Errors -or $Errors.Count -eq 0) { $result.reason = "no history"; return $result }
    $triggers = $Rule.triggers
    $matched = 0
    foreach ($err in $Errors) {
        $shouldMatch = $false
        if ($Rule.id -eq "clixml-stderr-filter" -and $err.clixml_stripped) { $shouldMatch = $true }
        elseif ($triggers.type -eq "any" -or $triggers.type -eq $err.type) {
            if (-not $triggers.pattern_in_command -or $err.command_summary -match $triggers.pattern_in_command) {
                $shouldMatch = $true
            }
        }
        if ($shouldMatch) { $matched++ }
    }
    $total = $Errors.Count
    if ($total -gt 0 -and ($matched / $total) -ge 0.1) {
        $result.passed = $true; $result.matched = $matched
        $result.bonus = [Math]::Min(30, [int](($matched / $total) * 50))
        $result.reason = "hit_rate=$([Math]::Round($matched * 100 / $total, 1))% matched=$matched total=$total"
    } else { $result.reason = "low_hit_rate: $([Math]::Round($matched * 100 / $total, 1))%" }
    return $result
}

# ═══════════════════════════════════════════════
# Update-Confidence
# ═══════════════════════════════════════════════
function Update-Confidence {
    $rules = Get-Rules -ForceReload
    if (-not $rules) { return }
    $changed = $false
    foreach ($rule in $rules) {
        if ($rule.is_template -or $rule.auto_generated -ne $true -or $rule.disabled) { continue }
        $hits = [int]$rule.hits
        $misses = if ($rule.misses) { [int]$rule.misses } else { 0 }
        $total = $hits + $misses
        if ($total -ge 50 -and $hits -eq 0) {
            $rule.disabled = $true
            $rule.disabled_reason = "auto-disabled: zero hits after $total commands"
            $changed = $true
            RE-Log "CONF" "Disabled: $($rule.id) - zero hits after $total commands"
        }
    }
    if ($changed) { Save-Rules $rules }
}

RE-Log "ENGINE" "V5 Rule Engine loaded: Init-RuleEngine, Get-Rules, Save-Rules, Apply-Rules, Filter-CLIXML, Log-ExecutionError, Generate-Rules, Test-RuleAgainstHistory, Update-Confidence"
