$wPid = 30424
Start-Sleep 3
taskkill /F /PID $wPid /T 2>$null
Start-Sleep 2
schtasks /run /tn BridgeCluster-file 2>$null
