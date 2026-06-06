# Bridge latency micro-benchmark
# Measures pure execution overhead of the bridge dispatch mechanism
$results = @()
1..10 | ForEach-Object {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = "ping"
    $sw.Stop()
    $results += "run_${_}: $($sw.ElapsedMilliseconds)ms"
}
$results | ForEach-Object { Write-Output $_ }

# Now measure actual work
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = Get-Date
$sw.Stop()
Write-Output "get-date: $($sw.ElapsedMilliseconds)ms"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$null = Get-Process | Select-Object -First 5
$sw.Stop()
Write-Output "get-process(5): $($sw.ElapsedMilliseconds)ms"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$testPath = "D:\zebbingo\tools\claude-bridge\watcher\.latency_test"
1..100 | ForEach-Object { "line$_" } | Out-File $testPath -Encoding utf8
$content = Get-Content $testPath
Remove-Item $testPath -Force
$sw.Stop()
Write-Output "file-rw-100lines: $($sw.ElapsedMilliseconds)ms ($($content.Count) lines read)"

Write-Output "done"
