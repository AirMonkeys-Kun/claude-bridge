$ErrorActionPreference = "Continue"
$bridgeBase = "D:\zebbingo\tools\claude-bridge"
$factory = Join-Path $bridgeBase "cluster\worker_factory.ps1"

Write-Output "KillAll..."
& $factory -KillAll
Start-Sleep 2

$types = @(
  @{t="generic";c=4},
  @{t="file";c=4},
  @{t="process";c=2},
  @{t="system";c=2},
  @{t="wsl";c=1},
  @{t="user";c=1}
)

foreach ($item in $types) {
  Write-Output "Creating $($item.t) x$($item.c)..."
  & $factory -Type $item.t -Count $item.c -BridgeBase $bridgeBase
  Start-Sleep 1
}

Write-Output "=== POOL STATUS ==="
& $factory -List
