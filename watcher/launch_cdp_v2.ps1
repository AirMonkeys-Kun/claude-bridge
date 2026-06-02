# Launch Claude Desktop with CDP debugging - v2
$logFile = "C:\Users\wsx\Desktop\claude-bridge\watcher\cdp_v2.log"

function Log { param($msg) "$(Get-Date -Format 'HH:mm:ss') $msg" | Out-File $logFile -Append }

Log "=== CDP Launch v2 ==="

try {
    # Check cmdlet
    $cmd = Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue
    if (-not $cmd) { Log "ERROR: Cmdlet not found"; exit 1 }
    Log "Cmdlet available"

    # Try both paths - relative package path first
    $paths = @(
        "app\Claude.exe",
        "C:\Program Files\WindowsApps\Claude_1.6608.2.0_x64__pzs8sxrjxfjjc\app\Claude.exe"
    )

    foreach ($exePath in $paths) {
        Log "Trying: $exePath --remote-debugging-port=9222"
        try {
            Invoke-CommandInDesktopPackage -PackageFamilyName "Claude_pzs8sxrjxfjjc" -AppId "Claude" -Command "$exePath --remote-debugging-port=9222 --no-sandbox"
            Log "SUCCESS with: $exePath"
            break
        }
        catch {
            Log "FAILED with $exePath : $_"
        }
    }
}
catch {
    Log "ERROR: $_"
}
