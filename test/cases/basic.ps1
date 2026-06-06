<#
.SYNOPSIS
    Basic command execution tests — echo, pwd, dir
.DESCRIPTION
    Verifies that the watcher can dispatch and execute basic commands.
    Uses __INLINE__ for in-process execution and powershell for subprocess.
#>
param([string]$BridgeBase = "", [switch]$PassThru)

$ErrorActionPreference = "Continue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
if (-not $BridgeBase) { $BridgeBase = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$watcherDir = Join-Path $BridgeBase "watcher"
$queueFile = Join-Path $watcherDir "queue.txt"
$fixturesFile = Join-Path $PSScriptRoot "..\fixtures\basic-commands.json"

function Log($m) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | [BASIC] $m" }
$results = @{total=0; passed=0; failed=0; skipped=0}
$failures = @()

function Wait-Result($cid, $timeout) {
    $deadline = (Get-Date).AddSeconds($timeout + 5)
    $resultFile = Join-Path $watcherDir "r_${cid}.json"
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $resultFile) {
            try {
                $content = [System.IO.File]::ReadAllText($resultFile, $utf8)
                $result = $content | ConvertFrom-Json
                Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
                return $result
            } catch { Start-Sleep -Milliseconds 100 }
        }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Write-Queue($cid, $cmd, $type, $timeout) {
    $payload = "{`"state`":`"pending`",`"cmd_id`":`"$cid`",`"command`":`"$($cmd -replace '"', '\"')`",`"type`":`"$type`",`"timeout`":$timeout}"
    [System.IO.File]::WriteAllText($queueFile, $payload, $utf8)
}

function Run-Test($name, $scriptBlock) {
    $results.total++
    try {
        & $scriptBlock
        $results.passed++
        Log "PASS: $name"
    } catch {
        $results.failed++
        $failures += "$name : $_"
        Log "FAIL: $name : $_"
    }
}

# ── Test cases ──
Log "=== Basic Tests ==="

Run-Test "INLINE echo" {
    Write-Queue "test_echo" "echo BRIDGE_TEST_OK" "__INLINE__" 10
    $r = Wait-Result "test_echo" 10
    if (-not $r) { throw "No result for test_echo" }
    if ($r.state -ne "done") { throw "State=$($r.state)" }
    if ($r.stdout -notmatch "BRIDGE_TEST_OK") { throw "stdout mismatch: $($r.stdout)" }
    Log "  test_echo: OK (${r.duration_ms}ms)"
}

Run-Test "INLINE Get-Date" {
    Write-Queue "test_date" "(Get-Date).ToString('yyyy-MM-dd')" "__INLINE__" 10
    $r = Wait-Result "test_date" 10
    if (-not $r) { throw "No result for test_date" }
    if ($r.state -ne "done") { throw "State=$($r.state)" }
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($r.stdout -ne $today) { throw "date mismatch: '$($r.stdout)' != '$today'" }
    Log "  test_date: OK (${r.duration_ms}ms)"
}

Run-Test "INLINE empty command" {
    Write-Queue "test_empty" "Write-Output ''" "__INLINE__" 10
    $r = Wait-Result "test_empty" 10
    if (-not $r) { throw "No result for test_empty" }
    if ($r.state -ne "done") { throw "State=$($r.state)" }
    Log "  test_empty: OK (${r.duration_ms}ms)"
}

Run-Test "INLINE error handling" {
    Write-Queue "test_error" "throw 'TEST_ERROR'" "__INLINE__" 10
    $r = Wait-Result "test_error" 10
    if (-not $r) { throw "No result for test_error" }
    if ($r.state -ne "error") { throw "Expected error state, got $($r.state)" }
    if ($r.stderr -notmatch "TEST_ERROR" -and $r.error -notmatch "TEST_ERROR") { throw "No TEST_ERROR in stderr/error" }
    Log "  test_error: OK (state=error, error=$($r.error))"
}

# Summary
Log ""
$passRate = if ($results.total -gt 0) { "{0:P1}" -f ($results.passed / $results.total) } else { "0%" }
Log "=== Results: $($results.passed)/$($results.total) passed ($passRate) ==="
if ($failures.Count -gt 0) {
    Log "Failures:"
    foreach ($f in $failures) { Log "  - $f" }
}

if ($PassThru) { return $results } elseif ($results.failed -gt 0) { exit 1 } else { exit 0 }
