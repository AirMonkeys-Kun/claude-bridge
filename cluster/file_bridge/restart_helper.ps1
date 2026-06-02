Start-Sleep 3
taskkill /F /PID 5472 /T 2>$null
Start-Sleep 2
Stop-ScheduledTask -TaskName 'BridgeCluster-file' -ErrorAction SilentlyContinue
Start-Sleep 1
Start-ScheduledTask -TaskName 'BridgeCluster-file' -ErrorAction SilentlyContinue
