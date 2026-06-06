# Check proxy server status
$proc = Get-Process -Name python -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'server\.py' } | Select-Object Id
if (-not $proc) {
    Write-Output "proxy_status=stopped"
    exit 0
}
$portInfo = try {
    $c = Get-NetTCPConnection -LocalPort 4000 -ErrorAction Stop
    "state=$($c.State)"
} catch {
    "state=no_connection"
}
Write-Output "proxy_status=running pid=$($proc.Id) $portInfo"
