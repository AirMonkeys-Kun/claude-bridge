# Launch Claude Desktop with CDP debugging
$logFile = "C:\Users\wsx\Desktop\claude-bridge\watcher\cdp_launch.log"

function Log { param($msg) "$(Get-Date -Format 'HH:mm:ss') $msg" | Out-File $logFile -Append }

Log "=== CDP Launch Attempt ==="
Log "PackageFamilyName: Claude_pzs8sxrjxfjjc"
Log "AppId: Claude"

try {
    # First check Invoke-CommandInDesktopPackage is available
    $cmd = Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Log "ERROR: Invoke-CommandInDesktopPackage not available"
        exit 1
    }
    Log "Cmdlet available: $($cmd.Name)"

    # Launch Claude with CDP using Invoke-CommandInDesktopPackage
    Log "Launching Claude.exe --remote-debugging-port=9222..."

    # Use Start-Process inside the package context
    Invoke-CommandInDesktopPackage -PackageFamilyName "Claude_pzs8sxrjxfjjc" -AppId "Claude" -Command "C:\Program Files\WindowsApps\Claude_1.6608.2.0_x64__pzs8sxrjxfjjc\app\Claude.exe --remote-debugging-port=9222 --no-sandbox" -Wait

    Log "Command completed"
}
catch {
    Log "ERROR: $_"
    exit 1
}
