$q = 'D:\zebbingo\tools\claude-bridge\watcher\queue.txt'
$wd = 'D:\zebbingo\tools\claude-bridge\watcher'
$log = 'D:\zebbingo\tools\claude-bridge\watcher\.bench_light_log'
$utf8 = [System.Text.UTF8Encoding]::new($false)

"START $(Get-Date -Format o)" | Out-File $log -Encoding utf8

function Wait-Idle {
    param([int]$TimeoutMs = 5000)
    for ($i = 0; $i -lt ($TimeoutMs / 10); $i++) {
        try {
            $st = ([System.IO.File]::ReadAllText($q, $utf8) | ConvertFrom-Json).state
            if ($st -eq 'idle') { return $true }
        } catch {}
        Start-Sleep -Milliseconds 10
    }
    return $false
}

function Send-Cmd {
    param([string]$Cid, [string]$Cmd)
    $payload = '{"state":"pending","cmd_id":"' + $Cid + '","command":"' + $Cmd + '","type":"powershell","timeout":10}'
    [System.IO.File]::WriteAllText($q, $payload, $utf8)
}

function Wait-Result {
    param([string]$Cid, [int]$TimeoutMs = 10000)
    $rFile = Join-Path $wd "r_${Cid}.json"
    for ($i = 0; $i -lt ($TimeoutMs / 10); $i++) {
        if (Test-Path $rFile) {
            try {
                $c = [System.IO.File]::ReadAllText($rFile, $utf8)
                if ($c) { return $c | ConvertFrom-Json }
            } catch {}
        }
        Start-Sleep -Milliseconds 10
    }
    return $null
}

$results = @()
$probe = "'PROBE'"
for ($i = 1; $i -le 5; $i++) {
    if (-not (Wait-Idle)) { "WARN: queue not idle before iter $i" | Out-File $log -Append -Encoding utf8; continue }
    $cid = "bench_light_${i}_$(Get-Date -Format 'HHmmssfff')"
    Send-Cmd -Cid $cid -Cmd $probe
    $r = Wait-Result -Cid $cid
    if ($r) {
        $results += [PSCustomObject]@{
            iter = $i
            cid = $cid
            duration_ms = $r.duration_ms
            fast_path = $r.fast_path
            stdout = $r.stdout
        }
    } else {
        $results += [PSCustomObject]@{ iter = $i; cid = $cid; duration_ms = -1; fast_path = $null; stdout = 'TIMEOUT' }
    }
}

"--- Per-iter results ---" | Out-File $log -Append -Encoding utf8
$results | Format-Table -AutoSize | Out-String | Out-File $log -Append -Encoding utf8

$ok = $results | Where-Object { $_.duration_ms -ge 0 }
if ($ok) {
    $avg = ($ok | Measure-Object duration_ms -Average).Average
    $min = ($ok | Measure-Object duration_ms -Minimum).Minimum
    $max = ($ok | Measure-Object duration_ms -Maximum).Maximum
    "--- Stats ---" | Out-File $log -Append -Encoding utf8
    "n=$($ok.Count) avg=$([math]::Round($avg,1))ms min=$min ms max=$max ms" | Out-File $log -Append -Encoding utf8
}
"DONE $(Get-Date -Format o)" | Out-File $log -Append -Encoding utf8
