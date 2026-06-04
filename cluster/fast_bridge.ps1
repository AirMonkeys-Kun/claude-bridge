# fast_bridge.ps1 — reads batch result from unique file immediately
param([string]$BasePath = "D:\zebbingo\tools\claude-bridge\cluster")
$batchNum = [int]$args[0]
if(-not $batchNum) { $batchNum = Read-Host "Batch number" }
$uniqPath = Join-Path $BasePath "_res$batchNum.txt"
$stdPath = Join-Path $BasePath ".pipe_batch_result.json"
if(Test-Path $uniqPath) {
    Get-Content $uniqPath -Raw
} else {
    Write-Host "WAITING for unique result..."
    $timeout = Get-Date
    while(-not (Test-Path $uniqPath) -and ((Get-Date) - $timeout).TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 50
    }
    if(Test-Path $uniqPath) { Get-Content $uniqPath -Raw }
    elseif(Test-Path $stdPath) { Get-Content $stdPath -Raw }
    else { "TIMEOUT" }
}