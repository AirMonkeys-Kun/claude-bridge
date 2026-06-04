$taskName = "BridgeGuardian-V3"
$guardScript = "D:\zebbingo\tools\claude-bridge\cluster\guardian_v3.ps1"

# Delete old task if exists
schtasks /Delete /TN $taskName /F 2>$null

# Create via schtasks directly (simplest approach, always works)
$args = @(
    "/Create", "/SC", "MINUTE", "/MO", "1",
    "/TN", $taskName,
    "/TR", "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$guardScript`"",
    "/RL", "HIGHEST",
    "/F"
)
$result = Start-Process -FilePath "schtasks.exe" -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
Write-Host "schtasks exit: $($result.ExitCode)"
if ($result.ExitCode -eq 0) {
    Write-Host "SUCCESS: Guardian task registered"
    # Trigger first run
    schtasks /Run /TN $taskName 2>$null
} else {
    Write-Host "FAILED"
    exit 1
}
