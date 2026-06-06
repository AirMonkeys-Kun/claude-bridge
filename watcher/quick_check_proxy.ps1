$line = netstat -ano | Select-String ":4000 "
if (-not $line) {
    Write-Output "PROXY=NOT_RUNNING"
    exit 1
}
Write-Output "NETSTAT: $line"
$parts = $line -split '\s+'
$pid = $parts[-1]
if ($pid -match '^\d+$') {
    $p = Get-Process -Id $pid -ErrorAction SilentlyContinue
    if ($p) {
        Write-Output "PID=$pid START=$($p.StartTime.ToString('HH:mm:ss'))"
    }
}
