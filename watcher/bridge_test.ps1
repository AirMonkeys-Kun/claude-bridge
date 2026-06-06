# Bridge Communication Test Suite
# Tests round-trip latency, output handling, error cases
$results = @()

function Run-Test($name, $scriptBlock) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $out = & $scriptBlock 2>&1
        $sw.Stop()
        $results += [PSCustomObject]@{
            Test   = $name
            Status = "OK"
            Ms     = $sw.ElapsedMilliseconds
            Output = ($out | Out-String).Trim().Substring(0, [Math]::Min(120, ($out | Out-String).Trim().Length))
        }
    } catch {
        $sw.Stop()
        $results += [PSCustomObject]@{
            Test   = $name
            Status = "FAIL"
            Ms     = $sw.ElapsedMilliseconds
            Output = $_.Exception.Message.Substring(0, [Math]::Min(120, $_.Exception.Message.Length))
        }
    }
    return $results[-1]
}

# Test 1: Simple echo
$r = Run-Test "echo" { echo "hello bridge" }
Write-Output "[$($r.Status)] echo ($($r.Ms)ms): $($r.Output)"

# Test 2: PowerShell computation
$r = Run-Test "compute" { [math]::Round([math]::PI * 1000, 4) }
Write-Output "[$($r.Status)] compute ($($r.Ms)ms): $($r.Output)"

# Test 3: Date/time
$r = Run-Test "datetime" { Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff" }
Write-Output "[$($r.Status)] datetime ($($r.Ms)ms): $($r.Output)"

# Test 4: File write + read
$r = Run-Test "file-io" {
    $testFile = "D:\zebbingo\tools\claude-bridge\watcher\.bridge_test_tmp"
    "test-$(Get-Date -Format 'fffffff')" | Out-File $testFile -Encoding utf8
    $content = Get-Content $testFile -Raw
    Remove-Item $testFile -Force
    $content.Trim()
}
Write-Output "[$($r.Status)] file-io ($($r.Ms)ms): $($r.Output)"

# Test 5: Process info
$r = Run-Test "process" {
    $p = Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'server\.py' } | Select-Object -First 1
    if ($p) { "proxy_pid=$($p.Id)" } else { "proxy_not_running" }
}
Write-Output "[$($r.Status)] process ($($r.Ms)ms): $($r.Output)"

# Test 6: Network check
$r = Run-Test "port-check" {
    $c = Get-NetTCPConnection -LocalPort 4000 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { "port_4000=LISTENING pid=$($c.OwningProcess)" } else { "port_4000=NOT_LISTENING" }
}
Write-Output "[$($r.Status)] port-check ($($r.Ms)ms): $($r.Output)"

# Test 7: Multi-line output
$r = Run-Test "multiline" {
    1..5 | ForEach-Object { "line_$_" }
}
Write-Output "[$($r.Status)] multiline ($($r.Ms)ms): $($r.Output)"

# Test 8: Error handling (intentional)
$r = Run-Test "error-case" {
    Get-Item "D:\nonexistent_path_xyz" -ErrorAction Stop
}
Write-Output "[$($r.Status)] error-case ($($r.Ms)ms): $($r.Output)"

Write-Output ""
Write-Output "=== Bridge test complete ==="
