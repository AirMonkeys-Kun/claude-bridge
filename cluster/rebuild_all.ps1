$factory = "D:\zebbingo\tools\claude-bridge\cluster\worker_factory.ps1"
$ErrorActionPreference = "Continue"

Write-Output "=== Phase 1: KillAll ==="
& $factory -KillAll 2>&1
Start-Sleep 1

$types = @(@("generic",4), @("file",4), @("process",2), @("system",2), @("wsl",1), @("user",1))

foreach ($pair in $types) {
  $t = $pair[0]; $c = $pair[1]
  Write-Output "=== $t x$c ==="
  & $factory -Type $t -Count $c -BridgeBase "D:\zebbingo\tools\claude-bridge" 2>&1
  Start-Sleep 1
}

Write-Output "=== Pool Summary ==="
& $factory -List 2>&1
