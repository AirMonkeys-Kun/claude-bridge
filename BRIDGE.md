# Claude Bridge Cluster — 通信桥技术文档

> 最后更新：2026-06-01 | 版本：v4

---

## 目录

1. [架构概览](#1-架构概览)
2. [协议规范](#2-协议规范)
3. [Worker 配置](#3-worker-配置)
4. [Master Scheduler](#4-master-scheduler)
5. [已知问题与解决方案](#5-已知问题与解决方案)
6. [跨机器迁移流程](#6-跨机器迁移流程)
7. [故障排查](#7-故障排查)
8. [CHANGELOG](#8-changelog)

---

## 1. 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                    Claude (本 Agent)                      │
│  写入 queue.txt → 轮询 r_{cmd_id}.json 获取结果          │
└──────────────────────┬──────────────────────────────────┘
                       │ 文件 IPC
┌──────────────────────▼──────────────────────────────────┐
│                    Master Scheduler                       │
│              (master_scheduler.ps1, 可选路由层)           │
│   读取 master_queue.txt → 按 channel 分发到 worker       │
└──────┬──────┬──────┬──────┬──────┬──────┬──────┬───────┘
       │      │      │      │      │      │      │
       ▼      ▼      ▼      ▼      ▼      ▼      ▼
   ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────┐
   │  file  │ │registry│ │process │ │network │ │ system │ │  wsl   │ │ watcher  │
   │_bridge │ │_bridge │ │_bridge │ │_bridge │ │_bridge │ │_bridge │ │(监视器)  │
   └────────┘ └────────┘ └────────┘ └────────┘ └────────┘ └────────┘ └──────────┘
```

### 核心概念

- **Worker（工人）**：每个 worker 是一个独立的 PowerShell 进程，专职处理一个领域
- **IPC**：所有通信通过文件系统完成（queue.txt + 结果 JSON 文件）
- **Watcher**：每个 worker 内部包含一个 watcher 主循环（200ms 轮询 queue.txt）
- **Master Scheduler**：（可选）中间路由层，可从 master_queue.txt 读取并按 channel 分发
- **直接模式**：Claude 可直接写入任意 worker 的 queue.txt，绕过 scheduler

### Worker 类型

| Worker | 目录 | 职责 |
|--------|------|------|
| file_bridge | `cluster/file_bridge/` | 文件读写、下载、属性操作 |
| process_bridge | `cluster/process_bridge/` | 进程管理、命令行执行、状态检查 |
| network_bridge | `cluster/network_bridge/` | 网络操作、端口、防火墙、DNS |
| system_bridge | `cluster/system_bridge/` | 系统服务、计划任务、配置 |
| registry_bridge | `cluster/registry_bridge/` | 注册表操作 |
| wsl_bridge | `cluster/wsl_bridge/` | WSL/Linux 操作（当前不可用） |

### 启动方式

每个 worker 由 Windows Scheduled Task 启动：
```
名称：BridgeCluster-{worker}
触发器：系统启动时
操作：powershell -NoProfile -ExecutionPolicy Bypass -File cluster\worker_template.ps1 -WorkerName {worker}_bridge -BridgeBase {bridge_root}
注意：Scheduled Task 名称不含 `_bridge` 后缀，但 WorkerName 参数包含。例如 `BridgeCluster-file` → `-WorkerName file_bridge`
```

---

## 2. 协议规范

### 请求格式（queue.txt）

```json
{
  "state": "pending",
  "cmd_id": "unique_command_id",
  "command": "要执行的命令",
  "type": "powershell",
  "timeout": 30
}
```

### state 流转

```
pending → running → (done / error)
        ↕               ↕
     idle (空闲)    结果写入 r_{cmd_id}.json
```

### type 取值

| type | 说明 | 执行方式 |
|------|------|----------|
| `powershell` | PowerShell 命令 | 通过 `-EncodedCommand` 启动子进程（有 CLIXML 在 stderr）|
| `powershell_text` | PowerShell 命令（无 CLIXML）| 通过 `-Command "..."` 启动子进程（推荐 ✅）|
| `cmd` | CMD 命令 | 通过 `cmd /c` 启动子进程 |
| `wsl` | WSL bash 命令 | 通过 `wsl.exe -e bash -c` 启动（⚠️ 当前不可用）|
| `__INLINE__` | 内联执行 | 在当前 worker 进程中用 `ScriptBlock.Create` 执行 |

### 响应格式（r_{cmd_id}.json）

```json
{
  "state": "done",
  "cmd_id": "unique_command_id",
  "exit_code": 0,
  "stdout": "命令输出内容",
  "stderr": "错误输出",
  "error": "",
  "duration_ms": 1234,
  "timestamp": "2026-06-01 11:09:20.758"
}
```

### 超时行为

- 子进程超时后会被 `$p.Kill()` 强行终止
- 返回 `state: "error"`, `exit_code: -1`, `stdout: "[TIMEOUT after ${timeout}s]"`
- worker 内置额外 2 秒容忍（`WaitForExit(timeout+2)`）
- INLINE 执行没有超时机制（除非手动在命令中处理）

---

## 3. Worker 配置

### 目录结构

```
cluster/{worker_name}/
├── queue.txt            # 请求队列（读写）
├── .watcher.lock        # PID 锁文件
├── .watcher_heartbeat   # 心跳文件（每 200ms 更新）
├── watcher.log          # 执行日志
├── r_{cmd_id}.json      # 各命令的执行结果
```

### 模板文件

所有 worker 使用同一模板：`cluster/worker_template.ps1`

主要参数：
- `-WorkerName`：worker 名称（如 `file_bridge`）
- `-BridgeBase`：bridge 根目录（自动检测或手动指定）

### 内联执行（INLINE）

`__INLINE__` 类型在 worker 进程中直接执行 PowerShell 代码：
- 快速（50-300ms）、无子进程开销
- 可以访问 worker 进程的变量和状态
- **危险**：出错会导致 worker 进程异常，且 `taskkill` 可能影响父进程
- **⚠️ 陷阱**：在 `$_` 后紧跟 `:` 字符会触发 PowerShell 解析错误

```powershell
# BAD — 会报错："变量引用无效"
$pids | ForEach-Object { "Trying PID $_: " + ... }

# GOOD — 使用 ${_} 避免歧义
$pids | ForEach-Object { "Trying PID ${_}: " + ... }
```

---

## 4. Master Scheduler

`master_scheduler.ps1` 是一个可选路由层，提供：
- **channel 路由**：按 channel 字段自动分发到对应 worker
- **健康检查**：`__STATUS__` 命令返回所有 worker 状态报告
- **结果等待**：自动轮询 worker 结果并汇总
- **去重**：防止同一 cmd_id 被重复分发

### 使用方式

通过 `master_queue.txt` 提交命令：

```json
{
  "state": "pending",
  "cmd_id": "my_task_001",
  "channel": "process",
  "command": "Get-Process | Select-Object -First 5",
  "type": "powershell",
  "timeout": 30
}
```

### channel 映射

| channel | 路由到 | 说明 |
|---------|--------|------|
| `file` | file_bridge | 文件操作 |
| `registry` | registry_bridge | 注册表操作 |
| `process` | process_bridge | 进程管理 |
| `network` | network_bridge | 网络操作 |
| `system` | system_bridge | 系统服务 |
| `wsl` | wsl_bridge | WSL/Linux |

---

## 5. 已知问题与解决方案

### 5.1 多行 stdout 截断 ✅ 已修复（v4）

**问题**：子进程的 stdout 只捕获部分行，后续行丢失。经历了三个版本才找到根因。

**v2 尝试**：在 timed `WaitForExit` 后加 parameterless `WaitForExit()` + sleep 排空 async 事件。
- ❌ 效果：5 行只捕获 1 行（异步事件有竞态条件）

**v3 尝试**：改用同步 `ReadToEnd()` 在 `WaitForExit` 之后。
- ❌ 效果：5 行只捕获 3 行（pipe buffer 竞态 — 进程退出后管道未完全排空）

**v4 最终修复**：使用 `ReadToEndAsync()` 在后台持续读取，`WaitForExit(ms)` 等待进程完成，再用 `task.Result` 取回完整输出。
- ✅ 效果：所有类型（cmd/powershell/powershell_text）均完整捕获

```powershell
# v4 正确做法（worker_template.ps1）：
$outTask = $p.StandardOutput.ReadToEndAsync()    # 后台持续读取
$errTask = $p.StandardError.ReadToEndAsync()

if ($p.WaitForExit(($origTimeout+2) * 1000)) {
    $exitCode = $p.ExitCode
    $stdout = $outTask.Result    # 进程已退出，数据已到位
    $stderr = $errTask.Result
} else {
    $p.Kill()
    # 超时后尝试获取已读取的部分输出
    try { $stdout = $outTask.Result } catch { $stdout = "" }
}
```

**根因**：.NET 的管道缓冲区在进程退出后不会立即对 `ReadToEnd()` 可见。`ReadToEndAsync()` + `WaitForExit()` + `task.Result` 的组合确保在进程运行期间持续读取管道，避免竞态。

参考：https://stackoverflow.com/questions/13967712/

### 5.2 INLINE `$_` 解析错误

**问题**：`ForEach-Object { "Trying PID $_: done" }` 报错"变量引用无效"。

**原因**：PowerShell 解析器在 `$_` 后遇到 `:` 时错误地将 `$_:` 解析为成员访问语法。

**解决方案**：使用 `${_}` 语法：
```powershell
ForEach-Object { "Trying PID ${_}: done" }
```

### 5.3 taskkill /F 挂死

**问题**：当一个 worker 的子进程正在 `WaitForExit`（内核级等待）时，在该 worker 或其兄弟 worker 中用 `taskkill /F` 杀进程会挂死。

**原因**：`WaitForExit` 是一个内核等待操作，`taskkill /F` 无法中断内核态等待。

**规则**：
- 不要从 worker 的子进程或 INLINE 中 `taskkill` 该 worker 或其他 worker
- 使用 `Stop-Process -Id $pid -Force` 替代 `taskkill`
- 或通过 Scheduled Task 重启（系统会自动清理旧进程）

### 5.4 WSL Bridge 不可用

**问题**：`wsl_test_01` 返回 `WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED`。

**原因**：WSL 未在主机上正确配置（可能未安装或系统账户不支持 WSL）。

**状态**：待主机侧修复 WSL 配置。当前 `wsl_bridge` worker 存活但不可用。

### 5.5 SYSTEM 账户下 Get-AppxPackage 超时

**问题**：以 SYSTEM 身份运行的 worker 执行 `Get-AppxPackage -AllUsers` 会超时。

**原因**：SYSTEM 账户没有完整用户配置文件，无法枚举 AppX 包。

**替代方案**：
```powershell
# 不工作（超时）
Get-AppxPackage -AllUsers | Where-Object { $_.Name -like '*Codex*' }

# 工作正常（系统级查询）
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*Codex*' }
```

### 5.6 Bootstrap 死锁 — 全部 Worker 停机后无法远程恢复

**问题**：当所有 worker 进程被杀或崩溃后，Claude 无法通过桥接系统执行任何命令（所有执行通道均不可用），形成死锁。

**原因**：桥接系统依赖存活的 worker 来执行命令。若全部 worker 停止，没有任何机制能远程重启它们。

**解决方案**（选择其一）：

**方案 A：手动启动**（推荐）
以管理员身份运行：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\zebbingo\claude-bridge\cluster\start-workers.ps1
```

**方案 B：V2 Guardian（自动恢复）**
注册一个 Guardian Scheduled Task，每 2 分钟检查所有 worker 心跳，发现离线时自动重启：
```cmd
# 以管理员身份运行
D:\zebbingo\claude-bridge\cluster\register_v2_guardian.bat
```

Guardian 机制说明：
- `v2_guardian.bat` — 监控脚本，检查 `.watcher_heartbeat` 时效（120s 阈值）
- `register_v2_guardian.bat` — 注册为 Scheduled Task（每 2 分钟运行一次，SYSTEM 权限）
- 检测到心跳过期 → 杀残留进程 → 重置队列 → 启动 Scheduled Tasks

### 5.7 编码问题导致 register-workers.ps1 通过子进程执行失败

**问题**：通过桥接系统执行 `register-workers.ps1`（含中文字符）时，PowerShell 解析器报错。

**原因**：PowerShell 的 `-EncodedCommand` 参数传递包含中文的脚本文件路径，子进程编码解析不一致导致 AST 解析失败。

**解决方案**：
- 直接在本地控制台以管理员身份运行 `register-workers.ps1`
- 或通过 `start-workers.ps1` 绕过注册步骤直接启动

### 5.8 SYSTEM 账户下 Get-ScheduledTask 超时

**问题**：以 SYSTEM 身份运行的 worker 执行 `Get-ScheduledTask -TaskName 'BridgeGuardian-V2'` 超时。

**原因**：SYSTEM 账户没有完整的用户配置文件，查询 Task Scheduler COM 接口时性能极差（10s+）。

**解决方案**：使用 `schtasks /Query /FO CSV /NH /TN {TaskName}` 替代 `Get-ScheduledTask`，响应时间 < 2s。

---

## 6. 跨机器迁移流程

从一台电脑迁移到另一台电脑：

### 步骤 1：在新机器上部署文件

```
D:\zebbingo\claude-bridge\cluster\
├── worker_template.ps1          # 复制
├── master_scheduler.ps1         # 复制
├── {每个 worker 目录}/           # 创建目录结构
│   ├── queue.txt                # 创建空闲队列（可选）
│   └── .watcher.lock            # 会被自动创建
└── process_bridge\              # 至少需要 process_bridge
    └── watcher.log              # 会被自动创建
```

### 步骤 2：注册 Scheduled Tasks

以管理员身份运行，注册所有 worker 和 watcher：

```powershell
# 示例：注册 file_bridge
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File D:\zebbingo\claude-bridge\cluster\worker_template.ps1 -WorkerName file_bridge -BridgeBase D:\zebbingo\claude-bridge"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "BridgeCluster-file_bridge" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force
```

需要注册的 6 个 worker（使用 `register-workers.ps1` 一键注册）：

| Task 名称 | WorkerName 参数 |
|-----------|----------------|
| `BridgeCluster-file` | `file_bridge` |
| `BridgeCluster-registry` | `registry_bridge` |
| `BridgeCluster-process` | `process_bridge` |
| `BridgeCluster-network` | `network_bridge` |
| `BridgeCluster-system` | `system_bridge` |
| `BridgeCluster-wsl` | `wsl_bridge` |

> ⚠️ 注意：任务名是 `BridgeCluster-{worker}`（无 `_bridge` 后缀），但 WorkerName 参数是 `{worker}_bridge`。

### 步骤 3：启动 Worker

```powershell
# 一键启动所有 worker
powershell -NoProfile -ExecutionPolicy Bypass -File D:\zebbingo\claude-bridge\cluster\start-workers.ps1
```

或使用 Scheduled Task：
```powershell
Get-ScheduledTask -TaskName "BridgeCluster-*" | Start-ScheduledTask
```

### 步骤 4：注册 Guardian（可选但推荐）

定时检查 worker 心跳，自动恢复：
```cmd
D:\zebbingo\claude-bridge\cluster\register_v2_guardian.bat
```

### 步骤 5：验证

```powershell
# 快速健康检查（管理员身份）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\zebbingo\claude-bridge\cluster\cluster-health.ps1

# 或者手动检查心跳文件
Get-ChildItem D:\zebbingo\claude-bridge\cluster\*\watcher_heartbeat | Select-Object DirectoryName, LastWriteTime
```

### 步骤 6：配置 CLAUDE.md

在新机器上更新 CLAUDE.md 中的 bridge 路径（如有变化）。

---

## 7. 故障排查

### Worker 不响应

1. 检查 queue.txt 是否卡在 `running` 状态 → 手动重置为 `idle`
2. 检查 watcher.log 最新条目 → 确认是否正常轮询
3. 检查 `.watcher.lock` → 确认 PID 是否存活
4. 检查 Scheduled Task → 确认任务是否在运行

### Worker 反复崩溃

1. 检查 watcher.log 末尾几行 → 查找崩溃原因
2. 确认没有端口或文件冲突
3. 尝试手动启动测试：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File cluster\worker_template.ps1 -WorkerName file_bridge -BridgeBase D:\zebbingo\claude-bridge
   ```

### 结果文件写入失败

- 确认 worker 目录存在且有写权限
- 确认磁盘空间充足
- 检查 watcher.log 的写入异常日志

### 日志分析

每个 worker 的 watcher.log 包含：
```
2026-06-01 11:03:57.380 | [file_bridge] [dl_cx_final] type=powershell cmd=... timeout=900s
2026-06-01 11:18:55.175 | [file_bridge] [dl_cx_final] exit=0 out=73chars err=11chars
2026-06-01 11:18:55.192 | [file_bridge] [dl_cx_final] result written
```

搜索格式：
- `type=` — 查找执行的命令
- `exit=` — 查看退出码
- `TIMEOUT` — 查找超时的命令
- `exception` — 查看异常

---

## 8. CHANGELOG

### v4 (2026-06-01) — 多行输出最终修复 + Guardian 注册

- **修复**：多行 stdout 截断的根因修复 — 使用 `ReadToEndAsync()` + `WaitForExit(ms)` + `task.Result`
- **新增**：`powershell_text` 执行类型 — 通过 `-Command "..."` 避免 CLIXML 污染 stderr
- **新增**：`cluster-health.ps1` — 集群健康检查脚本（心跳/PID/多行测试）
- **新增**：Guardian V2 已注册 — `BridgeGuardian-V2` 每 2 分钟检查心跳，自动恢复
- **修复**：`start-workers.ps1` 任务名修正（`BridgeCluster-$w` → 去掉 `_bridge` 后缀）
- **清理**：158 个过期结果文件 + 7 个旧命名规范目录
- **文档**：迁移流程修正 Scheduled Task 命名；新增 5.8 SYSTEM下 Get-ScheduledTask 超时说明

历史演变：
```
v1 (初始)       — 异步 BeginOutputReadLine — 多行截断严重（~1/5行）
v2 (参数修复)    — 加 parameterless WaitForExit() — 仍然丢失（~1/5行）
v3 (内部迭代)    — 同步 ReadToEnd() 后 WaitForExit — 部分解决（~3/5行）
v4 ✅ (最终)     — ReadToEndAsync() + WaitForExit + task.Result — 100%
```

### v2.1 (2026-06-01)

- **新增**：`start-workers.ps1` — 一键启动所有 worker，自动清理残留 lock 和队列
- **新增**：`v2_guardian.bat` — 心跳监控 + 自动恢复（每 2 分钟检查 `.watcher_heartbeat`）
- **新增**：`register_v2_guardian.bat` — 注册 guardian 为 SYSTEM Scheduled Task
- **文档**：新增 bootstrap 死锁问题（5.6）和编码问题（5.7）
- **文档**：迁移流程增加 guardian 注册步骤

### v2 (2026-06-01)

- **修复**：多行 stdout 截断 — 在 timed WaitForExit 后增加 parameterless WaitForExit()
- **修复**：INLINE `$_:` 解析问题 — 使用 `${_}` 替代
- **新增**：本文档（BRIDGE.md）
- **新增**：`register-workers.ps1` — 一键管理脚本（register/start/stop/restart/status/cleanup）
- **改进**：worker_template.ps1 增加 v2 版本注释和详细说明

### v1 (初始版本)

- 初始集群桥实现
- 6 个 worker + master_scheduler
- 基于文件 IPC 的 queue/json 协议
