Write-Output "=== Claude Process Path ==="
$p = Get-Process -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) { Write-Output "PID=$($p.Id) Path=$($p.Path) Session=$($p.SessionId)" }

Write-Output "=== AppX Packages ==="
Get-AppxPackage -Name *Claude* -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output "Name=$($_.Name) Family=$($_.PackageFamilyName) Location=$($_.InstallLocation)"
}
if (-not (Get-AppxPackage -Name *Claude* -ErrorAction SilentlyContinue)) {
    Write-Output "No AppX Claude package found"
}

Write-Output "=== Loopback Exempt ==="
CheckNetIsolation LoopbackExempt -s 2>$null | Select-String -Pattern "Claude" -SimpleMatch
if (-not (CheckNetIsolation LoopbackExempt -s 2>$null | Select-String -Pattern "Claude")) {
    Write-Output "No Claude loopback exemption found"
}
