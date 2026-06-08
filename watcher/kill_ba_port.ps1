$pids = @()
netstat -ano | Select-String ':19850' | Select-String 'LISTENING' | ForEach-Object {
    $parts = $_ -split '\s+'
    $procId = $parts[-1]
    if ($procId -match '^\d+$') { $pids += $procId }
}
$pids = $pids | Select-Object -Unique
Write-Output "Found $($pids.Count) PIDs on port 19850"
foreach ($p in $pids) {
    Write-Output "Killing PID=$p"
    taskkill /F /PID $p 2>&1 | Out-String
}
Start-Sleep 2
Write-Output "===AFTER==="
netstat -ano | Select-String ':19850' | Select-String 'LISTENING'
