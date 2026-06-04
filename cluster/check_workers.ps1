$ErrorActionPreference = "SilentlyContinue"
$procs = Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "worker_generic|Cluster_Wkr" }
if (-not $procs) { Write-Output "No worker processes found"; exit }

Write-Output "Found $($procs.Count) worker processes:"
foreach ($p in $procs) {
  $cl = ($p.CommandLine -replace ".{80}$","...") -replace "\r?\n"," "
  Write-Output "  PID=$($p.Id) $cl"
}

# Also check pool file
if (Test-Path "D:\zebbingo\tools\claude-bridge\cluster\.worker_pool.json") {
  $pool = Get-Content "D:\zebbingo\tools\claude-bridge\cluster\.worker_pool.json" -Raw | ConvertFrom-Json
  Write-Output "`nPool file: $($pool.workers.Count) workers registered"
} else {
  Write-Output "`nNo pool file"
}
