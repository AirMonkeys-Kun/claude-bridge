# Restart Claude Desktop normally (no CDP flags)
# Uses COM Shell.Application which worked in testing
$ErrorActionPreference = "Continue"

Write-Host "=== Restart Claude Desktop ==="

# Method 1: COM Shell.Application
try {
    $shell = New-Object -ComObject Shell.Application
    $shellFolder = $shell.NameSpace("shell:AppsFolder")
    $app = $shellFolder.ParseName("Claude_pzs8sxrjxfjjc!Claude")
    if ($app) {
        $app.InvokeVerb("open")
        Write-Host "COM Shell.Application: invoked"
    } else {
        Write-Host "COM Shell.Application: app not found"
    }
}
catch { Write-Host "COM failed: $_" }

Start-Sleep -Seconds 5

# Check
$proc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
if ($proc) {
    Write-Host "Claude is running! PID: $($proc.Id -join ' ')"
} else {
    Write-Host "Claude is NOT running"
}
