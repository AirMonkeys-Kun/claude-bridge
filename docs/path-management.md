# Claude Bridge 路径管理优化

## 问题

原始项目所有脚本使用硬编码的 `C:\Users\wsx\Desktop\claude-bridge\` 路径。当项目从 wsx 的电脑迁移到当前机器时，因路径不同导致所有集群脚本（workers、scheduler）无法启动。

## 解决方案

所有 `cluster/` 目录下的核心脚本改为运行时自动检测项目根路径，不再依赖硬编码路径。

## 自动检测模式

### PowerShell 脚本

| 文件位置 | 检测方式 | 结果 |
|---|---|---|
| `cluster/*.ps1` | `$PSScriptRoot` | 取父目录得到 bridge 根 |
| `cluster/*_bridge/runner.ps1` | `Split-Path -Parent` 连续 3 层 | 从 `*_bridge/` 上溯到 bridge 根 |
| `worker_template.ps1` | `$PSScriptRoot → Split-Path -Parent` | `-BridgeBase` 参数变为可选 |
| `master_scheduler.ps1` | `$PSScriptRoot → Split-Path -Parent` | `-BridgeBase` 参数变为可选 |

### 批处理文件

| 文件 | 检测方式 |
|---|---|
| `launch_sched.bat` | `%~dp0` |
| `launch_workers.bat` | `%~dp0` |
| `sync_workers.bat` | `%~dp0` |
| `stop_cluster.bat` | `%~dp0` |

## 迁移步骤

1. 复制整个 `claude-bridge` 目录到新机器
2. 以管理员身份运行：
   ```powershell
   cd <bridge-root>\cluster
   .\start_cluster.ps1
   ```
3. 脚本会自动检测路径、注册 SYSTEM 任务、启动集群

## 受影响文件（已修复）

```
cluster/worker_template.ps1        — BridgeBase 自动检测 + _bridge 双后缀修复
cluster/master_scheduler.ps1       — BridgeBase 自动检测
cluster/start_cluster.ps1          — 文件式注册替代编码命令
cluster/scheduled_tasks.json       — 更新路径 + 迁移警告
cluster/collect_state.ps1          — $env:LOCALAPPDATA 替代硬编码
cluster/test_launch.ps1            — Join-Path $PSScriptRoot
cluster/scheduler_runner.ps1       — $PSScriptRoot 自动检测
cluster/file_bridge/runner.ps1     — 3 层 Split-Path -Parent
cluster/registry_bridge/runner.ps1 — 同上
cluster/process_bridge/runner.ps1  — 同上
cluster/network_bridge/runner.ps1  — 同上
cluster/system_bridge/runner.ps1   — 同上
cluster/wsl_bridge/runner.ps1      — 同上
cluster/launch_sched.bat           — %~dp0
cluster/launch_workers.bat         — %~dp0
cluster/sync_workers.bat           — %~dp0
cluster/stop_cluster.bat           — %~dp0
cluster/launch_scheduler.ps1       — $MyInvocation.MyCommand.Path
cluster/redeploy_file.ps1          — $MyInvocation.MyCommand.Path
```

## 未修复的文件

`watcher/` 目录下约 100+ 个一次性诊断脚本仍含 `C:\Users\wsx` 硬编码路径。这些脚本不是集群运行必需的遗留代码，建议在需要时清理。
