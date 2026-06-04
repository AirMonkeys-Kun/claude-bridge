$taskName = "BridgeGuardian-V3"
$guardScript = "D:\zebbingo\tools\claude-bridge\cluster\guardian_v3.ps1"
$xmlFile = "D:\zebbingo\tools\claude-bridge\cluster\_guardian_task.xml"

Write-Host "=== Registering Guardian v3 ==="
Write-Host "Task: $taskName"

# Delete old task (ignore errors - task might not exist)
schtasks /Delete /TN $taskName /F 2>nul
Write-Host "Old task cleaned"

# Create XML
$today = (Get-Date).ToString("yyyy-MM-dd") + "T00:00:00"
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Claude Bridge V21 Guardian v3 - Watcher health check every 60s</Description>
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
      <UserId>PC-20260509PHQZ\Administrator</UserId>
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
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$guardScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

[System.IO.File]::WriteAllText($xmlFile, $xml, [System.Text.Encoding]::Unicode)
Write-Host "XML written OK"

# Register
Write-Host "Running schtasks /Create..."
$result = schtasks /Create /XML $xmlFile /TN $taskName /F 2>&1
Write-Host "schtasks result: $result"

Remove-Item $xmlFile -Force -ErrorAction SilentlyContinue
Write-Host "XML cleaned"

if ($LASTEXITCODE -eq 0) {
    Write-Host "=== GUARDIAN REGISTERED SUCCESSFULLY ==="
    schtasks /Run /TN $taskName 2>$null
} else {
    Write-Host "=== GUARDIAN REGISTRATION FAILED (exit=$LASTEXITCODE) ==="
    exit 1
}
