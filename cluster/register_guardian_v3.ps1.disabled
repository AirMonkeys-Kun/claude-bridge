#Requires -Version 5.0 -RunAsAdministrator
<#
 Claude Bridge V21 — Register Guardian v3 Scheduled Task
 ──────────────────────────
 Registers guardian_v3.ps1 as a Scheduled Task running every 60 seconds
 as the current user (Administrator) with highest privileges.

 Uses BootTrigger + CalendarTrigger for maximum reliability:
   - BootTrigger: fires on EVERY system boot, repeats every 60s for 365 days.
     This NEVER expires — the system reboots at least yearly (updates, etc).
     No StartBoundary date to go stale.
   - CalendarTrigger: fires immediately on registration with today's date,
     repeats every 60s for 1 day. Provides instant start after registration.

 Watcher self-maintenance: watcher.ps1 housekeeping also re-registers this
 task periodically, so even if somehow the task expires, the watcher fixes it.

 V2.1 fixes:
   - $ErrorActionPreference = "Continue" (was "Stop" — caused schtasks /Delete
     for non-existent V2 task to trigger terminating error, aborting registration)
   - [System.IO.File]::WriteAllText for XML + log writes (no Out-File locking)
#>

param([switch]$Force)

$ErrorActionPreference = "Continue"
$utf8 = [System.Text.UTF8Encoding]::new($false)

$script:scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:bridgeBase = Split-Path -Parent $scriptPath
$script:guardianScript = Join-Path $script:scriptPath "guardian_v3.ps1"
$script:taskName = "BridgeGuardian-V3"
$script:xmlFile = Join-Path $script:scriptPath "_guardian_task.xml"

function Log($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | [REGISTER] $m"
}

# ── Verify guardian script exists ──
if (-not (Test-Path $script:guardianScript)) {
    Log "ERROR: guardian_v3.ps1 not found at $script:guardianScript"
    exit 1
}
Log "Guardian script: $script:guardianScript"

# ── Delete old broken task ──
Log "Removing any previous 'BridgeGuardian-V3' task..."
schtasks /Delete /TN "BridgeGuardian-V3" /F 2>$null
schtasks /Delete /TN "BridgeGuardian-V2" /F 2>$null
Log "  Old tasks removed"

# Also clean up any orphaned runner .bat files
Get-ChildItem (Join-Path $script:scriptPath "_guardian_*.bat") -ErrorAction SilentlyContinue | Remove-Item -Force

# ── Create XML task definition ──
# Two triggers:
#   1. BootTrigger: fires on every system boot, repeats every 60s for 365 days.
#      This NEVER expires because the system boots at least yearly.
#   2. CalendarTrigger: fires today, repeats every 60s for 1 day.
#      Provides instant startup after registration.
$currentUser = "$env:USERDOMAIN\$env:USERNAME"
Log "Creating task for user: $currentUser"

# The CalendarTrigger StartBoundary must be recent (< P1D ago)
$today = (Get-Date).ToString("yyyy-MM-dd") + "T00:00:00"

$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Claude Bridge V21 Guardian v3 — Watcher health check every 60s</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Repetition>
        <Interval>PT1M</Interval>
        <Duration>P365D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
    </BootTrigger>
    <CalendarTrigger>
      <StartBoundary>$today</StartBoundary>
      <Repetition>
        <Interval>PT1M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$currentUser</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>false</AllowHardTerminate>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$($script:guardianScript)"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# Write XML to temp file (UTF16 for schtasks compatibility)
Log "Writing task XML..."
[System.IO.File]::WriteAllText($script:xmlFile, $xmlContent, [System.Text.Encoding]::Unicode)

# Verify XML was written
if (-not (Test-Path $script:xmlFile)) {
    Log "ERROR: Failed to write XML file"
    exit 1
}
$xmlSize = (Get-Item $script:xmlFile).Length
Log "  XML written ($xmlSize bytes)"

# ── Register via schtasks with XML ──
Log "Registering task via schtasks /Create..."
$proc = Start-Process -FilePath "schtasks.exe" -ArgumentList @(
    "/Create", "/XML", "`"$script:xmlFile`"", "/TN", "`"$script:taskName`"", "/F"
) -NoNewWindow -Wait -PassThru

# Clean up XML file
Remove-Item $script:xmlFile -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -eq 0) {
    Log "Task '$script:taskName' registered successfully (exit=0)"
} else {
    Log "ERROR: schtasks /Create failed (exit=$($proc.ExitCode))"

    # Last resort: use create-with-bat approach (keep bat file)
    Log "  Trying alternate approach..."
    $batFile = Join-Path $script:scriptPath "_guardian_v3_runner.bat"
    $batContent = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($script:guardianScript)`"`r`n"
    [System.IO.File]::WriteAllText($batFile, $batContent, $utf8)

    $proc2 = Start-Process -FilePath "schtasks.exe" -ArgumentList @(
        "/Create", "/SC", "MINUTE", "/MO", "1",
        "/TN", "`"$script:taskName`"",
        "/TR", "`"$batFile`"",
        "/RL", "HIGHEST",
        "/F"
    ) -NoNewWindow -Wait -PassThru

    if ($proc2.ExitCode -eq 0) {
        Log "  Alternate approach succeeded (bat file retained at $batFile)"
    } else {
        Log "  FATAL: All registration methods failed"
        Log "  Manually run this command as Administrator:"
        Log "    schtasks /Create /SC MINUTE /MO 1 /TN `"$script:taskName`" /TR `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"`"$($script:guardianScript)`"`"`" /RL HIGHEST /F"
        exit 1
    }
}

# ── Verify ──
Start-Sleep -Seconds 2
Log "Verifying task..."
try {
    $taskOutput = schtasks /Query /FO CSV /NH /TN "$script:taskName" 2>&1
    Log "  Task status: $($taskOutput -join ' ')"
} catch {
    Log "  WARNING: Could not verify task: $_"
}

# ── Trigger first run ──
Start-Sleep -Seconds 1
Log "Triggering first run..."
try {
    schtasks /Run /TN "$script:taskName" 2>$null
    Log "  First run triggered (may take a few seconds to appear in log)"
} catch {
    Log "  WARNING: Could not trigger first run"
    Log "  (Guardian will run on next scheduled trigger within 1 minute)"
}

# ── Log to guardian log ──
$logFile = Join-Path (Join-Path $script:bridgeBase "watcher") "guardian_v3.log"
try {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    [System.IO.File]::AppendAllText($logFile, "$t | [REGISTER] Task '$script:taskName' registered — every 1 minute (BootTrigger+P365D)`r`n", $utf8)
} catch {}

Log ""
Log "=== Registration complete ==="
Log ""
Log "Guardian v3 is now scheduled. It will check watcher health every 60s."
Log "BootTrigger ensures it restarts on every system boot for 365 days."
Log ""
Log "Log:  $logFile"
Log "View: Get-Content '$logFile' -Tail 10"
Log "Unregister: schtasks /Delete /TN '$script:taskName' /F"
