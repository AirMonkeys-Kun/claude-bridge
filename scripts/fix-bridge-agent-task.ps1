# fix-bridge-agent-task.ps1 — Fix ClaudeBridgeAgent Scheduled Task
#
# Problem: Task shows 267011 (TASK_IS_STILL_ACTIVE) because bridge_agent.py
# is a long-running process that never exits. The task scheduler interprets
# this as "still running" instead of "success".
#
# Fix: Set ExecutionTimeLimit=PT0S (no time limit) and configure as
# "do not wait for completion" so the task launcher starts bridge_agent
# and reports success immediately.
#
# Note: Guardian V3 (BridgeGuardian-V3) monitors bridge_agent every 60s
# and auto-restarts it if it crashes. This scheduled task is only needed
# for the initial boot-time launch.

$ErrorActionPreference = "Continue"

$taskName = "ClaudeBridgeAgent"
$scriptPath = "D:\zebbingo\tools\claude-bridge\bridge_agent.py"

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Create the action — launch python with bridge_agent.py
$action = New-ScheduledTaskAction `
    -Execute "python.exe" `
    -Argument "`"$scriptPath`"" `
    -WorkingDirectory "D:\zebbingo\tools\claude-bridge"

# Trigger: at logon
$trigger = New-ScheduledTaskTrigger -AtLogon

# Settings: don't wait, no time limit, don't stop on idle
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew

$settings.RestartCount = 3
$settings.RestartInterval = (New-TimeSpan -Minutes 1)

# Register
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Start bridge_agent.py TCP gateway (port 19850) at logon. Guardian V3 monitors and auto-restarts if crashed." `
    -Force

# Verify
$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
Write-Output "Task: $($task.TaskName)"
Write-Output "State: $($task.State)"
Write-Output "Execute: $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
Write-Output "ExecutionTimeLimit: $($task.Settings.ExecutionTimeLimit)"
Write-Output "Done."
