<#
.SYNOPSIS
    Claude Bridge Integration Test Suite — one-click runner

.DESCRIPTION
    Discovers and runs all test cases in test/cases/, aggregates results,
    and produces a summary report. Supports individual case selection.

    Usage:
        .\test\test_all.ps1                          # Run all tests
        .\test\test_all.ps1 -Case basic              # Run only basic tests
        .\test\test_all.ps1 -Case bridge-agent       # Run only bridge_agent tests
        .\test\test_all.ps1 -List                    # List available test cases

.DESIGN
    Each test case is a standalone .ps1 file in test/cases/ that:
    - Accepts -BridgeBase and -PassThru parameters
    - Returns a result hashtable with total/passed/failed/skipped counts
    - Sets exit code 0 on success, 1 on failure (unless -PassThru)
#>

param(
    [string]$Case = "",
    [string]$BridgeBase = "",
    [switch]$List,
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"

# ── Determine paths ──
if (-not $BridgeBase) {
    $BridgeBase = Split-Path -Parent $PSScriptRoot
}
$testDir = Join-Path $BridgeBase "test"
$casesDir = Join-Path $testDir "cases"

$utf8 = [System.Text.UTF8Encoding]::new($false)

# ── Colors ──
$PASS = "PASS"
$FAIL = "FAIL"
$SKIP = "SKIP"

function Log($m) { Write-Host "$(Get-Date -Format 'HH:mm:ss.fff') | $m" }
function Log-Pass($m) { Write-Host "  [$PASS] $m" -ForegroundColor Green }
function Log-Fail($m) { Write-Host "  [$FAIL] $m" -ForegroundColor Red }
function Log-Skip($m) { Write-Host "  [$SKIP] $m" -ForegroundColor Yellow }

# ── List mode ──
if ($List) {
    Log "Available test cases:"
    $testCases = Get-ChildItem $casesDir -Filter "*.ps1" | Sort-Object Name
    foreach ($tc in $testCases) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($tc.Name)
        Log "  - $name"
    }
    return
}

# ── Discover test cases ──
if ($Case) {
    $testFiles = @(Join-Path $casesDir "${Case}.ps1")
    if (-not (Test-Path $testFiles[0])) {
        Log "ERROR: Test case '$Case' not found in $casesDir"
        Write-Host "  Use -List to see available cases"
        exit 1
    }
} else {
    $testFiles = @(Get-ChildItem $casesDir -Filter "*.ps1" | Sort-Object Name | ForEach-Object { $_.FullName })
}

Log "=" x 60
Log "Claude Bridge Integration Test Suite"
Log "  BridgeBase: $BridgeBase"
Log "  Test cases: $($testFiles.Count) found"
if ($Case) { Log "  Filter:     $Case" }
Log "=" x 60
Log ""

# ── Pre-flight checks ──
Log "Pre-flight checks..."

$watcherHb = Join-Path $BridgeBase "watcher\.watcher_heartbeat"
if (Test-Path $watcherHb) {
    $hb = Get-Content $watcherHb -Raw -ErrorAction SilentlyContinue
    if ($hb) {
        $age = [int]((Get-Date) - (Get-Date $hb.Trim())).TotalSeconds
        Log "  Watcher heartbeat: $($hb.Trim()) (age=${age}s)"
        if ($age -gt 180) { Log "  WARNING: Watcher heartbeat stale (>180s)" }
    }
} else {
    Log "  WARNING: No watcher heartbeat found (watcher may not be running)"
}

$queueFile = Join-Path $BridgeBase "watcher\queue.txt"
$queueReset = '{"state":"idle","cmd_id":"","command":"","type":""}'
[System.IO.File]::WriteAllText($queueFile, $queueReset, $utf8)
Log "  Queue reset to idle"

$emptyResultDir = $false
Get-ChildItem (Join-Path $BridgeBase "watcher") -Filter "r_*.json" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    $emptyResultDir = $true
}
if ($emptyResultDir) { Log "  Cleaned stale result files" }

Log ""

# ── Run test cases ──
$aggregate = @{total=0; passed=0; failed=0; skipped=0; duration_ms=0}
$caseResults = @()
$t0 = Get-Date

foreach ($tf in $testFiles) {
    $caseName = [System.IO.Path]::GetFileNameWithoutExtension($tf)
    Log "─" x 40
    Log "Running: $caseName"

    $ct0 = Get-Date
    try {
        $result = & $tf -BridgeBase $BridgeBase -PassThru
        $elapsed = [int]((Get-Date) - $ct0).TotalMilliseconds

        $aggregate.total += $result.total
        $aggregate.passed += $result.passed
        $aggregate.failed += $result.failed
        $aggregate.skipped += $result.skipped
        $aggregate.duration_ms += $elapsed

        $caseStatus = if ($result.failed -gt 0) { "FAIL" } else { "PASS" }
        $caseResults += @{name=$caseName; status=$caseStatus; passed=$result.passed; total=$result.total; duration=$elapsed}
        if ($result.failed -gt 0) {
            Log-Fail "$caseName — $($result.passed)/$($result.total) passed, $($result.failed) failed (${elapsed}ms)"
        } else {
            Log-Pass "$caseName — $($result.passed)/$($result.total) passed (${elapsed}ms)"
        }
    } catch {
        $elapsed = [int]((Get-Date) - $ct0).TotalMilliseconds
        $aggregate.failed++
        $aggregate.duration_ms += $elapsed
        $caseResults += @{name=$caseName; status="FAIL"; passed=0; total=0; duration=$elapsed}
        Log-Fail "$caseName — CRASHED: $_ (${elapsed}ms)"
    }

    # Brief pause between cases
    Start-Sleep -Milliseconds 500
}

$totalElapsed = [int]((Get-Date) - $t0).TotalMilliseconds

# ── Summary ──
Log ""
Log "=" x 60
Log "SUMMARY"
Log "=" x 60
foreach ($cr in $caseResults) {
    $icon = if ($cr.status -eq "PASS") { $PASS } else { $FAIL }
    $pct = if ($cr.total -gt 0) { "{0:P1}" -f ($cr.passed / $cr.total) } else { "0%" }
    Log "  [$icon] $($cr.name): $($cr.passed)/$($cr.total) ($pct) ${duration}ms"
}
Log ""

$pct = if ($aggregate.total -gt 0) { "{0:P1}" -f ($aggregate.passed / $aggregate.total) } else { "0%" }
$overall = if ($aggregate.failed -eq 0) { "ALL PASSED" } else { "${failed} FAILURES" }
Log "  Overall: $($aggregate.passed)/$($aggregate.total) tests passed ($pct)"
Log "  Duration: ${totalElapsed}ms total"
Log "  Status: $overall"
Log "=" x 60

$totalFailures = $aggregate.failed
if ($totalFailures -gt 0) { exit 1 } else { exit 0 }
