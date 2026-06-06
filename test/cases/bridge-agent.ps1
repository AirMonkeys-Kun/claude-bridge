<#
.SYNOPSIS
    bridge_agent health check — verifies bridge_agent is running and responds to TCP/health
.DESCRIPTION
    Tests the bridge_agent.py TCP gateway and the /health HTTP endpoint.
    Uses PowerShell to connect to Windows-localhost ports.
#>
param([string]$BridgeBase = "", [switch]$PassThru)

$ErrorActionPreference = "Continue"
if (-not $BridgeBase) { $BridgeBase = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

function Log($m) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | [BRIDGE-AGENT] $m" }
$results = @{total=0; passed=0; failed=0; skipped=0}
$failures = @()

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

Log "=== bridge_agent Tests ==="

Run-Test "bridge_agent TCP ping" {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect('127.0.0.1', 19850)
        $stream = $tcp.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.WriteLine('{"type":"ping"}')
        $writer.Flush()
        $resp = $reader.ReadLine()
        $tcp.Close()
        if (-not $resp) { throw "Empty response" }
        $json = $resp | ConvertFrom-Json
        if ($json.type -ne "pong") { throw "Expected pong, got $($json.type)" }
        Log "  PONG: workers=$($json.workers_alive)/$($json.workers_total) watcher=$($json.watcher_alive) pipe=$($json.pipe_mode)"
    } catch {
        throw "TCP ping failed: $_"
    }
}

Run-Test "bridge_agent health HTTP endpoint" {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect('127.0.0.1', 19851)
        $stream = $tcp.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.WriteLine("GET /health HTTP/1.1")
        $writer.WriteLine("Host: localhost")
        $writer.WriteLine("Connection: close")
        $writer.WriteLine()
        $writer.Flush()
        $resp = $reader.ReadToEnd()
        $tcp.Close()
        if (-not $resp) { throw "Empty response" }
        # Extract JSON body (after headers)
        $body = ($resp -split "`r`n`r`n")[-1]
        $json = $body | ConvertFrom-Json
        if ($json.status -ne "ok") { throw "Expected status=ok, got $($json.status)" }
        Log "  HEALTH: uptime=$($json.uptime_secs)s watcher=$($json.watcher_alive) watchdog=$($json.watchdog_alive) shutdown=$($json.shutting_down)"
    } catch {
        throw "Health check failed: $_"
    }
}

Run-Test "bridge_agent watchdog heartbeat" {
    $hbFile = Join-Path $BridgeBase "watcher\.watchdog_heartbeat"
    if (-not (Test-Path $hbFile)) { throw "Watchdog heartbeat file not found" }
    $hb = Get-Content $hbFile -Raw -ErrorAction SilentlyContinue
    if (-not $hb) { throw "Empty watchdog heartbeat" }
    $age = [int]((Get-Date) - (Get-Date $hb)).TotalSeconds
    if ($age -gt 180) { throw "Watchdog heartbeat stale: $age seconds old" }
    Log "  WATCHDOG HB: $($hb.Trim()) (age=${age}s)"
}

# Summary
$passRate = if ($results.total -gt 0) { "{0:P1}" -f ($results.passed / $results.total) } else { "0%" }
Log "=== Results: $($results.passed)/$($results.total) passed ($passRate) ==="
if ($failures.Count -gt 0) {
    Log "Failures:"
    foreach ($f in $failures) { Log "  - $f" }
}

if ($PassThru) { return $results } elseif ($results.failed -gt 0) { exit 1 } else { exit 0 }
