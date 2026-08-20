# ============================================================
#  注册 Claude Bridge 守护层为 Windows 登录自启（计划任务）
#  请以管理员身份运行本脚本。
#  作用: 用户登录后自动拉起 bridge_supervisor，桥在重启后也能自愈。
#  卸载: Unregister-ScheduledTask -TaskName "ClaudeBridgeSupervisor" -Confirm:$false
# ============================================================
$ErrorActionPreference = "Stop"

$taskName = "ClaudeBridgeSupervisor"
$python   = "C:\Program Files\Python313\python.exe"
$script   = "D:\zebbingo\tools\claude-bridge\bridge_supervisor.py"
$workdir  = "D:\zebbingo\tools\claude-bridge"

if (-not (Test-Path $python)) { Write-Error "找不到 Python: $python"; exit 1 }
if (-not (Test-Path $script)) { Write-Error "找不到 supervisor: $script"; exit 1 }

$action   = New-ScheduledTaskAction -Execute $python -Argument $script -WorkingDirectory $workdir
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$trigger.Delay = "PT01M"   # 登录后延迟 1 分钟，等桌面/网络就绪
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force

Write-Host "已注册计划任务 '$taskName'（登录后延迟 1 分钟自启）。"
Write-Host "立即测试: Start-ScheduledTask -TaskName $taskName"
Write-Host "卸载:     Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
