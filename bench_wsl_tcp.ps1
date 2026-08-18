$targetHost = '127.0.0.1'
$port = 19850
$log = 'D:\zebbingo\tools\claude-bridge\watcher\.bench_wsl_tcp_log'
"START $(Get-Date -Format o)" | Out-File $log -Encoding utf8

function Send-Tcp($cmd) {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect($targetHost, $port)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream, [Text.Encoding]::UTF8)
    $writer.AutoFlush = $true
    $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
    $payload = $cmd | ConvertTo-Json -Compress
    $writer.WriteLine($payload)
    $response = $reader.ReadLine()
    $writer.Close()
    $reader.Close()
    $client.Close()
    return ($response | ConvertFrom-Json)
}

"--- Health ping ---" | Out-File $log -Append -Encoding utf8
try {
    $ping = Send-Tcp @{ cmd_id = "ping_test"; type = "ping" }
    "ping: workers=$($ping.workers_alive) watcher=$($ping.watcher_alive)" | Out-File $log -Append -Encoding utf8
} catch {
    "ping FAILED: $($_.Exception.Message)" | Out-File $log -Append -Encoding utf8
}

$results = @()
for ($i = 1; $i -le 5; $i++) {
    $cmd = @{
        cmd_id = "wsl_tcp_${i}_$(Get-Date -Format 'HHmmssfff')"
        command = 'echo PROBE_TCP_WSL'
        type = 'wsl'
        timeout = 15
    }
    $t0 = Get-Date
    try {
        $r = Send-Tcp $cmd
        $elapsedTotal = [int]((Get-Date) - $t0).TotalMilliseconds
        $results += [PSCustomObject]@{
            iter = $i
            worker_ms = $r.duration_ms
            total_ms = $elapsedTotal
            channel = $r.dispatch_channel
            exit_code = $r.exit_code
            stdout_head = ($r.stdout -split "`n")[0]
        }
    } catch {
        $elapsedTotal = [int]((Get-Date) - $t0).TotalMilliseconds
        $results += [PSCustomObject]@{ iter=$i; worker_ms=-1; total_ms=$elapsedTotal; channel='ERROR'; exit_code=-1; stdout_head=$_.Exception.Message }
    }
    Start-Sleep -Milliseconds 200
}

"--- Per-iter ---" | Out-File $log -Append -Encoding utf8
$results | Format-Table -AutoSize | Out-String | Out-File $log -Append -Encoding utf8

$ok = $results | Where-Object { $_.worker_ms -ge 0 }
if ($ok) {
    $avgWorker = ($ok | Measure-Object worker_ms -Average).Average
    $minWorker = ($ok | Measure-Object worker_ms -Minimum).Minimum
    $maxWorker = ($ok | Measure-Object worker_ms -Maximum).Maximum
    $avgTotal = ($ok | Measure-Object total_ms -Average).Average
    "--- Stats ---" | Out-File $log -Append -Encoding utf8
    "n=$($ok.Count) worker avg=$([math]::Round($avgWorker,1))ms min=$minWorker max=$maxWorker | total avg=$([math]::Round($avgTotal,1))ms" | Out-File $log -Append -Encoding utf8
}
"DONE $(Get-Date -Format o)" | Out-File $log -Append -Encoding utf8
