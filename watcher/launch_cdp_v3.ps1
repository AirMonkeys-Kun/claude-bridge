# Launch Claude Desktop with CDP debugging - v3.4
# Uses the App Execution Alias to bypass MSIX Invoke-CommandInDesktopPackage issues
$logFile = "C:\Users\wsx\Desktop\claude-bridge\watcher\cdp_v3.log"
$ErrorActionPreference = "Continue"
$script:result = @()

function Log {
    param([string]$msg)
    $line = "$(Get-Date -Format 'HH:mm:ss') $msg"
    $script:result += $line
    Write-Host $line
}

Log "=== CDP Launch v3.4 ==="
Log "User: $env:USERNAME | Context: $env:USERDOMAIN"

# ---- Step 0: Find the App Execution Alias path ----
Log "--- Step 0: Locate App Execution Alias ---"
$aliasPaths = @(
    "$env:LOCALAPPDATA\Microsoft\WindowsApps\Claude.exe",
    "$env:LOCALAPPDATA\Microsoft\WindowsApps\ClaudeDesktop.exe",
    "$env:USERPROFILE\AppData\Local\Microsoft\WindowsApps\Claude.exe"
)

$aliasExe = $null
foreach ($p in $aliasPaths) {
    Log "Checking: $p"
    if (Test-Path $p) {
        $aliasExe = $p
        Log "FOUND: $p"
        break
    }
}

# Also search with cmd
if (-not $aliasExe) {
    Log "Searching via where.exe..."
    $whereResult = cmd /c "where Claude.exe 2>nul"
    foreach ($line in $whereResult) {
        if ($line -match "WindowsApps") {
            $aliasExe = $line.Trim()
            Log "FOUND via where: $aliasExe"
            break
        }
    }
}

if (-not $aliasExe) {
    Log "ERROR: Cannot find Claude App Execution Alias"
} else {
    Log "Using alias: $aliasExe"
}

# ---- Step 1: Detect running Claude ----
Log "--- Step 1: Check running Claude processes ---"
$claudeProcs = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
if ($claudeProcs) {
    Log "Found $($claudeProcs.Count) Claude process(es): $($claudeProcs.Id -join ' ')"

    # Check if port 9222 is already open
    $netstatBefore = netstat -ano | Select-String "9222"
    if ($netstatBefore) {
        Log ">>> Port 9222 ALREADY listening! CDP already active."
        Log ">>> SUCCESS! No need to relaunch."
        # Write log and exit
        $logText = $script:result -join "`r`n"
        try { $utf8 = New-Object System.Text.UTF8Encoding $false; [System.IO.File]::WriteAllText($logFile, $logText, $utf8) } catch {}
        exit 0
    }

    Log "Claude is running but CDP not active. Need to kill and restart with --remote-debugging-port."
}

# ---- Step 2: Kill Claude (if running) ----
$needsRestart = $false
if ($claudeProcs) {
    Log "--- Step 2: Kill Claude to restart with CDP flags ---"
    foreach ($p in $claudeProcs) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Log "Killed PID $($p.Id)"
        } catch { Log "Kill PID $($p.Id) failed: $_" }
    }
    Log "Waiting for full shutdown (10 seconds)..."
    Start-Sleep -Seconds 10
    $needsRestart = $true
} else {
    Log "Claude is not running - will launch fresh"
    $needsRestart = $true
}

# ---- Step 3: Launch with CDP via Alias ----
if ($needsRestart -and $aliasExe) {
    Log "--- Step 3: Launch Claude with --remote-debugging-port=9222 ---"
    Log "Using: $aliasExe --remote-debugging-port=9222 --no-sandbox"

    # Method A: Start-Process with the alias
    Log "Method A: Start-Process via alias..."
    try {
        $proc = Start-Process -FilePath $aliasExe -ArgumentList "--remote-debugging-port=9222", "--no-sandbox" -PassThru -NoNewWindow
        Log "Method A started PID: $($proc.Id)"
    } catch {
        Log "Method A failed: $_"

        # Method B: cmd /c start
        Log "Method B: cmd /c start..."
        try {
            $argStr = "--remote-debugging-port=9222 --no-sandbox"
            cmd /c "start `"`" `"$aliasExe`" $argStr"
            Log "Method B invoked"
        } catch {
            Log "Method B failed: $_"

            # Method C: direct invoke
            Log "Method C: direct invoke..."
            try {
                & $aliasExe --remote-debugging-port=9222 --no-sandbox
                Log "Method C invoked"
            } catch {
                Log "Method C failed: $_"
            }
        }
    }

    # Wait for app to start
    Log "Waiting for startup (10 seconds)..."
    Start-Sleep -Seconds 10

    # Check processes
    $newProcs = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
    if ($newProcs) {
        Log ">>> Claude process detected: $($newProcs.Id -join ' ')"

        $netstatCheck = netstat -ano | Select-String "9222"
        if ($netstatCheck) {
            Log ">>> CDP port 9222 is LISTENING!"
            Log ">>> SUCCESS! Full CDP mode achieved."
        } else {
            Log ">>> Claude running but port 9222 not detected"
        }
    } else {
        Log "No Claude process found after launch"
    }
}

# ---- Fallback: Try Invoke-CommandInDesktopPackage (Method 2 style) without kill first ----
# Only if alias approach failed and Claude is NOT running
$finalClaude = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
if (-not $finalClaude -and $needsRestart) {
    Log "--- Fallback: Invoke-CommandInDesktopPackage (fresh start) ---"
    try {
        Invoke-CommandInDesktopPackage -PackageFamilyName "Claude_pzs8sxrjxfjjc" -AppId "Claude" -Command "app\Claude.exe" -Args "--remote-debugging-port=9222 --no-sandbox" -ErrorAction Stop
        Log "Fallback success"
    } catch {
        Log "Fallback failed: $_"
        try {
            # One more try: no args at all, just launch
            Invoke-CommandInDesktopPackage -PackageFamilyName "Claude_pzs8sxrjxfjjc" -AppId "Claude" -Command "app\Claude.exe" -ErrorAction Stop
            Log "Fallback (no args) success"
        } catch {
            Log "Fallback (no args) failed: $_"
        }
    }
}

# ---- Summary ----
$finalCheck = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
if ($finalCheck) {
    Log "=== FINAL: Claude is running (PID: $($finalCheck.Id -join ' ')) ==="
} else {
    Log "=== FINAL: Claude is NOT running ==="
}

# Write log
$logText = $script:result -join "`r`n"
try {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($logFile, $logText, $utf8)
    Write-Host "`nLog written to: $logFile"
} catch {
    Write-Host "Log write error: $_"
    Write-Host "`n--- Full log ---"
    Write-Host $logText
}
