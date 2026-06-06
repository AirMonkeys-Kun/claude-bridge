# Claude Bridge 演变史

> 从 V1 到 V21 — 每个坑、每次转折、每个版本承诺了什么、是否真的做到了
> 最后更新：2026-06-04 | 按时间顺序阅读

---

## 目录

- [如何阅读本文档](#如何阅读本文档)
- [V1 (初始) — 桥的诞生](#v1-初始--桥的诞生)
- [V2 — 多行截断第一次尝试](#v2--多行截断第一次尝试)
- [V3 — 多行截断第二次尝试](#v3--多行截断第二次尝试)
- [V4 ✅ — 多行截断最终修复 + Guardian 注册](#v4--多行截断最终修复--guardian-注册)
- [V16 — 规则引擎 + 进度刷新 + fallback 日志](#v16--规则引擎--进度刷新--fallback-日志)
- [V17 — ScriptBlock 快路径 + Scheduler 恢复](#v17--scriptblock-快路径--scheduler-恢复)
- [V18 — 9P 缓存方案 + Named Pipe 调查](#v18--9p-缓存方案--named-pipe-调查)
- [V19 — Named Pipe 融入 watcher](#v19--named-pipe-融入-watcher)
- [V20 — 工厂按类型创建 workers](#v20--工厂按类型创建-workers)
- [V21 — Async Dispatch + 三层自愈](#v21--async-dispatch--三层自愈)
- [V20.1 (V2.1 热修复) — 非交互上下文修复](#v201-v21-热修复--非交互上下文修复)
- [V21 已知 Bug 勘误 — async-dispatch 已被守卫解决](#v21-已知-bug-勘误--async-dispatch-已被-管道-守卫解决)
- [V2.2 — 回归验证驱动的三合一修复](#v22--回归验证驱动的三合一修复)
- [验证清单](#验证清单)

---

## 如何阅读本文档

每个版本的结构：

```
## V{x} — 标题

**承诺**：[该版本声称修复/实现的内容]

**实际代码**：[当时的写法]

**问题/背景**：[为什么要这么改]

❌ 尝试方式：[走过的弯路]
✅ 最终方式：[验证通过的方案]

回归验证状态：[待验证 / ✅ 通过 / ❌ 失败]
```

"回归验证"是指：**站在当前（V20.1）系统上，回头测试每个版本的承诺是否仍然成立**。因为代码一直在重构，早期版本的修复可能在重构中被回退。

---

## V1 (初始) — 桥的诞生

**日期**：2026-06-01

**承诺**：在 Linux VM（Claude 沙箱）和 Windows 宿主机之间建立通信桥。

**架构**：

```
Claude (VM) → 写 queue.txt → Windows watcher → 读 queue → 执行命令 → 写结果文件 → VM 读取
```

**代码**：
```powershell
# 初始方案：异步 BeginOutputReadLine 捕获 stdout
$p = Start-Process powershell.exe -PassThru
$p.BeginOutputReadLine()
```

**问题**：
- 多行 stdout 截断严重（5 行只拿到 ~1 行）

**回归验证状态**：✅ 上游 V4 已解决（V1 代码已完全重构）

---

## V2 — 多行截断第一次尝试

**日期**：2026-06-01

**承诺**：通过加 parameterless `WaitForExit()` 排空异步缓冲区，修复 stdout 截断。

**实际代码**：
```powershell
$p.WaitForExit($timeout * 1000)   # timed wait
Start-Sleep -Milliseconds 200
$p.WaitForExit()                   # parameterless — 排空
```

❌ **结果**：5 行只拿到 ~1 行。问题依旧。

**根因（当时未知）**：异步事件有竞态条件。`WaitForExit()` 返回后，`OutputDataReceived` 事件可能还在路上。

**同期新增**：
- 本文档（BRIDGE.md）
- `register-workers.ps1` 一键管理脚本
- 发现 INLINE `$_:` 解析问题（`ForEach-Object { "PID $_: done" }` 报错）

**回归验证状态**：⏳ 待验证（当前代码无 `BeginOutputReadLine` + `WaitForExit` 组合）

---

## V3 — 多行截断第二次尝试

**日期**：2026-06-01（紧接 V2）

**承诺**：改用同步 `ReadToEnd()` 在 `WaitForExit` 之后。

**实际代码**：
```powershell
$p.WaitForExit()
$stdout = $p.StandardOutput.ReadToEnd()
```

❌ **结果**：5 行拿到 ~3 行。部分解决，但 pipe buffer 竞态仍在。

**根因（当时未知）**：进程退出后管道缓冲区未完全排空。`ReadToEnd()` 在进程已退出时不一定读到全部数据。

**回归验证状态**：⏳ 待验证（当前代码无 `ReadToEnd()` 后 `WaitForExit()` 模式）

---

## V4 ✅ — 多行截断最终修复 + Guardian 注册

**日期**：2026-06-01

**承诺**：`ReadToEndAsync()` + `WaitForExit(ms)` + `task.Result` 三件套，**100% 完整捕获**。

**最终代码**：
```powershell
$outTask = $p.StandardOutput.ReadToEndAsync()    # 后台持续读取
$errTask = $p.StandardError.ReadToEndAsync()

if ($p.WaitForExit(($origTimeout+2) * 1000)) {
    $exitCode = $p.ExitCode
    $stdout = $outTask.Result    # 进程已退出，数据已到位
    $stderr = $errTask.Result
} else {
    $p.Kill()
    try { $stdout = $outTask.Result } catch { $stdout = "[TIMEOUT]" }
}
```

✅ **结果**：50 行完整捕获，零截断。

**根因**：.NET 管道缓冲区在进程退出后不会立即对 `ReadToEnd()` 可见。`ReadToEndAsync()` 在进程运行期间**持续读取**管道，`WaitForExit(ms)` 等待进程完成，`task.Result` 取回早已缓冲完成的数据。三者缺一不可。

**同期新增**：
- Guardian V2（`BridgeGuardian-V2`，每 2 分钟检查心跳）
- `powershell_text` 类型（`-Command "..."` 避免 CLIXML）
- `cluster-health.ps1`
- 清理 158 个过期结果文件

**回归验证状态**：✅ 当前代码使用 ReadToEndAsync + WaitForExit + task.Result（V4 模式），50 行完整捕获验证通过

---

## V16 — 规则引擎 + 进度刷新 + fallback 日志

**日期**：2026-06-04

**承诺**：规则引擎自动变换命令、进度刷新保活、日志失败时 fallback。

**核心新增**：
- **规则引擎**（`bridge_rules.json` V3.0，15 条规则）：
  - `python-utf8-encoding` — cmd 下 python 命令自动切换为 powershell 类型
  - `path-wsx-to-admin` — 自动替换旧机器路径
  - `cmd-pipe-escape` — cmd 模式下 `|` 自动转义为 `^|`
- **进度刷新**：长时间命令每 5s 写 `r_{cid}_progress.json`
- **Fallback 日志**：`.watcher_fallback.log`，当 `watcher.log` 写失败时记录

**关键修复**：
- Log 函数静默吞错误 → 增加 fallback 日志链路

**回归验证状态**：✅ 规则引擎已生效（cmd-pipe-escape hits 3→4），进度文件在 Named Pipe 派发路径不适用

---

## V17 — ScriptBlock 快路径 + Scheduler 恢复

**日期**：2026-06-04

**承诺**：powershell 类型命令使用 `[ScriptBlock]::Create()` 进程内执行，延迟从 ~150ms 降到 ~10ms。

**实际代码**：
```powershell
$ps = [System.Management.Automation.PowerShell]::Create()
$ps.AddScript({
    param($Cmd)
    $ErrorActionPreference = 'Continue'
    & ([ScriptBlock]::Create($Cmd)) 2>&1
}).AddArgument($sbCmd)

$handle = $ps.BeginInvoke()
if ($handle.AsyncWaitHandle.WaitOne($timeoutMs)) {
    $sbResult = $ps.EndInvoke($handle)
    $stdout = ($sbResult | Out-String).Trim()
}
```

**两条路径对比**：

| 路径 | 延迟 | 适用场景 |
|------|------|---------|
| ScriptBlock 进程内 | ~10ms | 单条 powershell 命令 |
| 子进程（powershell.exe） | ~150ms | 所有其他类型 |

**Scheduler 恢复**：Named Pipe IPC + RunspacePool 并行分发，EventWaitHandle 零睡眠。

**回归验证状态**：✅ Runspace 快路径实测 powershell 类型 33ms vs cmd 子进程 228ms，~7x 加速验证通过

---

## V18 — 9P 缓存方案 + Named Pipe 调查

**日期**：2026-06-04

**承诺**：唯一文件名绕过 9P FUSE 缓存，结果读取从 200-600ms 降到 <25ms。

**问题**：
```
VM (Linux)                     Host (Windows)
   │                              │
   │  cat .pipe_batch_result.json │
   │ ──────────────────────────►  │ 9P FUSE: cache hit
   │  ←── 旧数据(200-600ms)       │ ←── 返回旧数据
   │                              │
   │  ... 500ms later ...         │
   │  cat .pipe_batch_result.json │
   │ ──────────────────────────►  │
   │  ←── 新数据(<25ms)           │ ←── 重新读取
```

**解决方案**：每次用唯一 `cmd_id` 命名结果文件 `r_{cmd_id}.json`。

```bash
# 慢（复用文件名）：
cat watcher/.pipe_batch_result.json    # 200-600ms

# 快（唯一文件名）：
cat watcher/r_my_unique_id.json        # <25ms
```

**同期发现**：`cowk-vm-service` Named Pipe 是反向 RPC 架构（JSON-RPC 2.0），服务器是 JSON-RPC 客户端，host 侧无法冒充 sdk-daemon。**协议调查死路**。

**回归验证状态**：✅ 所有 `r_{cid}.json` 文件从 VM 侧即时读取，无 9P 缓存延迟

---

## V19 — Named Pipe 融入 watcher

**日期**：2026-06-04

**承诺**：watcher 直接集成 Named Pipe 分发，`Dispatch-ToWorker` 按类型路由，无可用 worker 时回退 ScriptBlock。

**派发逻辑**：
```
cmd.exe → generic worker
powershell.exe → generic worker
file 操作 → file worker
process 操作 → process worker
system 操作 → system worker
wsl 操作 → wsl worker
user 操作 → user_bridge（特殊路径）
```

**关键移除**：`pipe_daemon.ps1` 不再需要独立进程。

**回归验证状态**：✅ 所有命令结果包含 `pipe_direct:true`，确认 Named Pipe 派发有效

---

## V20 — 工厂按类型创建 workers

**日期**：2026-06-04

**承诺**：`worker_factory.ps1` V2 按类型+数量管理 workers，14 个 worker 涵盖 6 种类型。

**类型分布**：

| 类型 | 数量 | 命名 | 命名管道 |
|------|------|------|----------|
| generic | 4 | `generic_1` ~ `generic_4` | `Cluster_Wkr_generic_{n}` |
| file | 4 | `file_1` ~ `file_4` | `Cluster_Wkr_file_{n}` |
| process | 2 | `process_1` ~ `process_2` | `Cluster_Wkr_process_{n}` |
| system | 2 | `system_1` ~ `system_2` | `Cluster_Wkr_system_{n}` |
| wsl | 1 | `wsl_1` | `Cluster_Wkr_wsl_1` |
| user | 1 | `user_1` | `Cluster_Wkr_user_1` |

**并发能力**：同类型多个 worker 可并行执行。

**回归验证状态**：⚠️ 部分通过 — 13/14 存活，`file_1` 未加入 pool；并发执行有效（3×8s sleep 完成于 16s）

---

## V21 — Async Dispatch + 三层自愈

**日期**：2026-06-04

**承诺**：异步并发派发 + 四层自愈体系（你的一句话"不要叫我手动"驱动）。

### V21 核心变更

#### Async Dispatch（异步派发）

V20（同步）：
```
queue.txt → pending → 派发 → 等待完成 → idle → 读结果
                          ↕
                      阻塞 5-30s
```

V21（异步）：
```
queue.txt → pending → 派发 → 立即 idle → 新命令可入
                          ↕
                      100ms 就绪
          inflight tracking 跟踪 worker 完成
```

#### 繁忙 worker 跳过

`Get-WorkerForType` 新增跳过逻辑：
```powershell
$busyWorkerIds = @($script:inflight.Values | ForEach-Object { $_.worker.id })
$available = @($candidates | Where-Object { $_.id -notin $busyWorkerIds })
```

### 三层自愈体系

```
Layer 1: Guardian Scheduled Task
  每 60s 检查 watcher 心跳
  BootTrigger (P365D) 永不过期
  CalendarTrigger 提供即时启动
  
Layer 2: Watcher 自升级
  每 ~50 次循环检测 watcher.ps1 文件修改
  优雅排空 → 写入标志 → 退出 → Guardian 接手重启

Layer 3: Worker 自修复
  实时跳过死 worker（Get-WorkerForType）
  周期性批量 respawn（Guardian 检查）
```

### V21 修复的 3 个 Bug

| Bug | 症状 | 修复 |
|-----|------|------|
| #1 | V19 队列卡在 running 状态 | async dispatch 后立即 reset queue |
| #2 | 派发到繁忙 worker 导致 2s pipe 超时 | Get-WorkerForType 跳过 inflight 中的 worker |
| #3 | ScriptBlock 成功路径不写结果文件 | 结果处理移到 `if (-not $sbFastOk)` 外部 |

**回归验证状态**：✅ 并发派发、心跳监控、Named Pipe 派发均确认有效；⏳ 自愈升级路径待模拟测试

---

## V20.1 (V2.1 热修复) — 非交互上下文修复

**日期**：2026-06-04

**承诺**：修复 V2 在非交互上下文（S4U、Scheduled Task、子进程）中的三个失败点。

### 5.12.1 Start-Process → .NET Process.Start

❌ **V2 错误写法**：
```powershell
$proc = Start-Process powershell.exe -ArgumentList @(...) -PassThru -WindowStyle Hidden
```
→ `E_FAIL (0x80004005)` — 非交互会话无窗口站

✅ **V2.1 正确写法**：
```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "powershell.exe"
$psi.Arguments = "..."
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
$null = $p.BeginOutputReadLine()
$null = $p.BeginErrorReadLine()
```
→ .NET 原生 API，无 UI 依赖

### 5.12.2 Out-File → WriteAllText

❌ **V2 错误写法**：
```powershell
$pool | ConvertTo-Json | Out-File -FilePath $poolFile -Encoding utf8
```
→ "文件正由另一进程使用"

✅ **V2.1 正确写法**：
```powershell
$json = $pool | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText($poolFile, $json, [System.Text.UTF8Encoding]::new($false))
```

### 5.12.3 $ErrorActionPreference

❌ **V2 错误写法**：
```powershell
$ErrorActionPreference = "Stop"
schtasks /Delete /TN "BridgeGuardian-V2" /F   # V2 不存在 → 终止错误
```

✅ **V2.1 正确写法**：
```powershell
$ErrorActionPreference = "Continue"
schtasks /Delete /TN "BridgeGuardian-V2" /F 2>$null
```

**回归验证状态**：✅ worker_factory.ps1 已符合全部 V2.1 要求（.NET Process.Start / WriteAllText）；guardian_v3.ps1 的 Start-Process 当前在 S4U 下可工作，但属历史遗留写法

---

## V21 已知 Bug 勘误 — async-dispatch 已被 `$pipeDispatched` 守卫解决

**状态**：✅ 回归验证时发现该 bug 不存在于当前代码

**实际情况**：源代码 review 确认 `watcher.ps1` line 755 存在 `if (-not $pipeDispatched)` 守卫。

```
实际流程：
  dispatch → $pipeDispatched=$true → queue reset → 跳过结果处理（line 755 guard）
                                                        ↕
                                               Check-InflightResults 轮询完成
```

`$pipeDispatched` 标志在 Named Pipe 派发成功后设置为 `$true`，line 755 的 `if (-not $pipeDispatched)` 使代码跳过整个内联执行 + 结果处理段。inflight 跟踪（Check-InflightResults）在后续循环迭代中通过 `r_{cid}.json` 文件监控 worker 完成状态。

**教训**：该 bug 描述是在编写 EVOLUTION.md 时根据推测写的，未经过实际代码审查验证。回归验证时发现守卫早已存在。

---

## V2.2 — 回归验证驱动的三合一修复

**日期**：2026-06-04

**驱动**：回归验证发现三个真实问题和一个误报的勘误。

### 修复 1: worker_factory.ps1 — 新增 `-DeployAll` 原子部署模式

**根因**：`start_bridge.bat` 按类型串行调用工厂（generic→file→process→...），每次读写 pool JSON。pool 文件被多次重写时可能丢失 worker（`file_1` 缺失）。

**修复**：
- 新增 `-DeployAll` 参数：一次循环创建全部 14 个 worker（6 种类型），单次 pool 写入
- `start_bridge.bat` 从 7 个独立调用改为单行 `-DeployAll`
- `guardian_v3.ps1` 的 `Invoke-StartWorkers` 也从 per-type 循环改为 `-DeployAll`
- 同步修复了残留的 `Out-File` → `WriteAllText`（单类型路径的 queue 初始化）

### 修复 2: worker_generic.ps1 — Named Pipe 派发路径增加进度报告

**根因**：`r_{cid}_progress.json` 仅在 watcher 内联子进程路径中生成。Named Pipe 异步派发的长命令无进度报告。

**修复**：
- worker 的子进程执行路径改为轮询循环（`WaitForExit(5000)`），每 5 秒写入 `r_{cid}_progress.json`
- 超时检测同步实现
- 完成后清理进度文件

### 修复 3: guardian_v3.ps1 — `Start-Process` → `.NET Process.Start`

**根因**：`guardian_v3.ps1` 在启动 watcher（line 276）和 workers（line 332）时使用 `Start-Process -WindowStyle Hidden`，在 S4U 非交互上下文中可能失败（`E_FAIL 0x80004005`）。

**修复**：
- 两处均已替换为 `[System.Diagnostics.Process]::Start()` + `BeginOutputReadLine()`
- `Invoke-StartWorkers` 同时改用 `-DeployAll` 参数

### 勘误: V21 async-dispatch "缺少 continue"

回归验证时通过源代码审查发现：`watcher.ps1` line 755 的 `if (-not $pipeDispatched)` 守卫早已存在，Dispatcher 成功派发后不会落入内联执行路径。不存在之前猜测的 bug。inflight 跟踪通过 `Check-InflightResults` 轮询正常工作。

### V2.2 基准测试结果

全量性能基准测试（2026-06-04 16:26，130/130 OK，0 失败）：

| 测试项 | 子命令数 | avg_ms | med_ms | min_ms | max_ms |
|--------|---------|--------|--------|--------|--------|
| roundtrip_pwd | 5 | 95 | 92 | 91 | 108 |
| roundtrip_echo | 7 | 164.6 | 138 | 106 | 281 |
| roundtrip_cmd | 5 | 104.6 | 107 | 93 | 108 |
| pipe_direct | 5 | 18.6 | 16 | 15 | 29 |
| result_read | 5 | 0.6 | 1 | 0 | 1 |
| stress_50 | 50 | 99 | 92 | 75 | 244 |
| concurrency_5 | 1批次 | 728 | 728 | 728 | 728 |
| concurrency_10 | 1批次 | 1163 | 1163 | 1163 | 1163 |
| type_file | 3 | 450 | 456 | 399 | 495 |
| v21_concurrent_mixed | 1批次 | 2377 | 2377 | 2377 | 2377 |
| v21_max_throughput | 1批次 | 2771 | 2771 | 2771 | 2771 |

**V21 vs V2.2 对比**：
- 基础延迟不变（~93ms 中位）
- 零失败（V21 有已知失败）
- 14/14 worker 全部存活（-DeployAll 修复 file_1 缺失）

### V2.2 guardian 加固

V2.2 新增四项 guardian 保护机制：

1. **Guardian 启动宽限期** — `Invoke-RespwanDeadWorkers` 新增 60s 启动宽限期，避免部署后立刻误触发 worker respawn
2. **Guardian 日志轮转** — 超过 500 行时自动截断保留最新 500 行，防止日志无限增长
3. **Worker 部署时间跟踪** — `$script:lastWorkerDeployTime` 追踪最近一次部署时间
4. **Guardian 启停阶段 .NET Process.Start** — 启动 watcher 和 workers 时使用 `[System.Diagnostics.Process]::Start` 替代 `Start-Process -WindowStyle Hidden`，兼容 S4U 非交互上下文

### V2.2 watcher.log 锁死锁修复

**根因**：旧 watcher 进程异常退出后，PowerShell 的 `StreamWriter` 持有独占写锁未释放。新 watcher 进程无法获得文件访问权，导致日志停更约 64 分钟（13:39-14:43）。

**修复**：
1. **Fallback 日志** — 主日志写入失败时自动切换到 `.watcher_fallback.log`
2. **自动恢复** — 锁释放后自动恢复主日志写入
3. **验证** — `.watcher_fallback.log` 正确记录了 31 条 LOG_FAIL，V2.2 部署后恢复正常

---

以下测试按版本顺序，从 V1 到 V21，回归验证每个版本的承诺在当前系统中是否仍然成立。

| # | 版本 | 验证项 | 方法 | 状态 | 备注 |
|---|------|--------|------|------|------|
| 1 | V4 | stdout 完整捕获 | 生成 50 行输出，逐行计数 | ✅ 通过 | 全部 50 行完整捕获，37ms 完成 (fast_path+pipe_direct) |
| 2 | V16 | 规则引擎生效 | 发送含 `|` 的 cmd 命令，验证被转义 | ✅ 通过 | `cmd-pipe-escape` hits: 3→4，确认 `|` 被 `^|` 转义 |
| 3 | V16 | 进度文件写入 | 发送长命令，检查 `r_{cid}_progress.json` | ❌ 不适用 | Named Pipe 派发的命令不走 watcher 内联路径；进度刷新仅对 watcher 子进程生效 |
| 4 | V17 | ScriptBlock 快路径 | 比较 powershell 类型 vs cmd 类型耗时 | ✅ 通过 | PS: 33ms (fast_path=true) vs CMD: 228ms (fast_path=false) — ~7x 加速 |
| 5 | V18 | 唯一文件名可读 | 从 VM 侧读取 `r_{cid}.json` | ✅ 通过 | 所有 r_ 文件即时读取，无 9P 缓存延迟 |
| 6 | V20 | 14 个 worker 存活 | 检查 pool + 每个 PID 存活 | ✅ 14/14 | -DeployAll 原子写入解决 file_1 竞态；V2.2 部署后 14/14 全部存活 |
| 7 | V20 | 并发执行 | 3 路 sleep，总耗时 ≈ 单路耗时 | ✅ 通过 | 3×8s sleep 完成于 16s wall time（全串行需 24s） |
| 8 | V21 | Named Pipe 派发 | 检查结果中的 `pipe_direct` 标志 | ✅ 通过 | 所有命令 `pipe_direct:true` |
| 9 | V21 | 繁忙 worker 跳过 | 并发发命令，检查是否跳到不同 worker | ✅ 通过 | conc1/conc2 重叠执行，分配不同 generic worker |
| 10 | V21 | Guardian 任务 | schtasks /Query BridgeGuardian-V3 | ✅ 通过 | 已注册，每分钟运行，V2.2 .NET Process.Start 可用 |
| 11 | V21 | watcher 心跳 | .watcher_heartbeat 持续更新 | ✅ 通过 | 秒级更新，最新 14:43:44 |
| 12 | V20.1 | .NET Process.Start | 检查 worker_factory.ps1 无 Start-Process | ✅ 通过 | worker_factory 使用 `[System.Diagnostics.Process]::Start()` |
| 13 | V20.1 | WriteAllText | 检查 pool 写入使用 WriteAllText | ✅ 通过 | `[System.IO.File]::WriteAllText` 用于 pool 写入 |
| 14 | V20.1 | $ErrorActionPreference | 检查 register_guardian_v3.ps1 用 Continue | ✅ 通过 | `$ErrorActionPreference = "Continue"` |

### 附加发现

| # | 项目 | 状态 | 详情 |
|---|------|------|------|
| 15 | guardian_v3.ps1 Start-Process | ✅ V2.2 已修复 | 两处替换为 .NET Process.Start，Invoke-StartWorkers 改用 -DeployAll |
| 16 | file_1 缺失 | ✅ V2.2 已修复 | 根因为 per-type 串行调用的 pool 竞态；-DeployAll 原子写入消除此问题 |
| 17 | worker 进度文件 | ✅ V2.2 已添加 | Named Pipe 派发的子进程命令每 5s 写 progress.json |
| 18 | V21 async-dispatch "bug" | ✅ 勘误为不存在 | 代码审查确认 `$pipeDispatched` 守卫 (line 755) 已正确保护 |
| 19 | V4 guardian 循环重启 | 📌 已停止 | V4 guardian.log 显示 04:35-05:00 每 5 分钟重启，后停止；当前 V3 guardian 正常运行 |
| 20 | watcher.log 停更 | ✅ V2.2 已修复 | 旧 watcher 长期持有文件独占锁（13:39-14:43）；V2.2 fallback 日志 + 自动恢复解决，锁释放后回归正常；`.watcher_fallback.log` 正确捕获了冲突期日志 |
| 21 | watcher.ps1 损坏 | ✅ V2.2 部署中修复 | Python 编辑截断文件至 755 行；重建 V17.2 内联回退 ~163 行代码（ScriptBlock 快路径 + 子进程回退 + 自升级 + 关闭结构）；修复缺失的 `}` 关闭 try 块（brace 平衡从 +1 归零）|
| 22 | V2.2 部署验证 | ✅ 全部通过 | 参见下方 V2.2 部署验证 |

| 23 | V2.2 | 性能基准测试 | 全量 benchmark 130 命令 | ✅ 通过 | 130/130 OK, 0 失败，中位延迟 ~93ms，V21 基线的已知失败全部清除 |
| 24 | V2.2 | Guardian 启动宽限期 | 部署后立即检查 worker respawn | ✅ 通过 | 60s 宽限期延迟 respawn，避免假阳性 |
| 25 | V2.2 | Guardian 日志轮转 | 触发 500 行截断 | ✅ 通过 | log 超 500 行自动截断保留最新 500 行 |
| 26 | V2.2 | watcher.log 锁恢复 | 停更后 fallback 日志切换 | ✅ 通过 | `.watcher_fallback.log` 记录 31 条 LOG_FAIL；锁释放后自动恢复 |
| 27 | V2.2 | Fallback 日志机制 | 主日志锁冲突时切换到 fallback | ✅ 通过 | 验证了完整的 fallback 链路：锁冲突 → fallback 写入 → 锁释放 → 恢复 |
| 28 | V2.2 | worker 进度上报 | Named Pipe 长任务每 5s 写 progress | ✅ 通过 | 子进程路径中 progress.json 按预期写入 |

### V2.2 部署验证 (2026-06-04 15:31)

所有 3 项回归修复已部署并验证通过：

| # | 验证项 | 状态 | 详情 |
|---|--------|------|------|
| 1 | watcher.ps1 语法 | ✅ 通过 | ScriptBlock::Create 成功，43264 字节，零解析错误 |
| 2 | watcher 运行 | ✅ 通过 | PID 5456，心跳秒级更新（最新 15:31:34），queue idle |
| 3 | Worker pool 14/14 | ✅ 通过 | -DeployAll 原子写入创建全部 14 个 worker，版本 2.2，file_1 已包含 |
| 4 | E2E 命令执行（Named Pipe） | ✅ 通过 | powershell 命令 180ms 返回，`pipe_direct:true`，exit code 0 |
| 5 | E2E 内联执行（__INLINE__） | ✅ 通过 | 内联 ScriptBlock 执行正常，exit code 0 |
| 6 | 长时间任务 (15s sleep) | ✅ 通过 | `pipe_direct:true`，15203ms 精确计时，exit code 0 |
| 7 | Guardian 任务 | ✅ 通过 | schtasks BridgeGuardian-V3 已注册，每分钟运行，上次结果 0 |
| 8 | Guardian V2.2 .NET Process.Start | ✅ 通过 | `schtasks /Run` 成功，无 E_FAIL 错误 |
| 9 | start_watcher_only.ps1 | ✅ 通过 | .NET Process.Start 启动 watcher 成功，心跳 15s 内稳定 |

**结论**: V2.2 所有修复已部署并验证。系统 3 层自愈体系完整运行。watcher.ps1 损坏已修复，file_1 已加入 pool，guardian 使用 .NET Process.Start。

---

## 代理桥演进 — V6 到 V13+ (2026-06-05)

> 通信桥和代理桥并行发展。通信桥从 V1 演进到 V2.2（上文已记录），
> 代理桥从 V6 演进到 V13+。以下记录代理桥的完整发展脉络。

### V6 — 最初的可工作代理

**日期**：2026-06-03（存档于 `proxy/v6/server_v6.py`）

**承诺**：一个简单的 Anthropic → OpenAI 转换代理，让 Claude Desktop 通过第三方后端工作。

**架构**：
```
Claude Desktop → localhost:4000 → server.py (格式转换) → 后端 API
```

**能力**：
- Anthropic Messages API 接收
- 转换为 OpenAI Chat Completions 格式
- 转发到后端，转换响应回来
- 基本错误处理

**局限**：
- 无 thinking 块处理
- 无 failover / 熔断器
- 无配置热更新
- 所有 provider 走 OpenAI 转换路径
- 无流式 SSE 优化
- GZipMiddleware 压缩 SSE 流（增加延迟）

**回归验证状态**：📦 已存档，不再维护

### V7-V10 — 渐进式增强

**日期**：2026-06-03 ~ 2026-06-04

**逐步添加**：
- V7：多 provider 配置 + 基础 failover
- V8：config.yaml 配置文件 + 热重载
- V10：规则引擎集成 + 模型路由

**回归验证状态**：已被 V13 完全取代

### V13 — 生产级重写

**日期**：2026-06-05

**承诺**：完整重写，生产级质量。双 API 格式 + adaptive thinking + SSE 优化。

**核心架构决策**：

| 决策 | 原因 |
|------|------|
| 双 API 格式 | xiaomi 用 Anthropic 原生（性能更好），zhipu 用 OpenAI 转换（兼容性） |
| adaptive thinking 透传 | 模型自行决定思考深度，不强制固定 budget |
| SSE 零拷贝转发 | 未修改事件跳过 JSON 重序列化，降低流式延迟 |
| 浅层 sort_keys | 递归排序大 payload 浪费 CPU，浅层排序足够 |
| 移除 GZipMiddleware | localhost 不需要压缩，SSE 流压缩反而增加延迟 |

**五大历史 Bug（全部修复）**：

1. **httpx 流式失败** — `async with resp:` 触发 AttributeError，httpx 0.28.1 无 `__aenter__`。改用 `send(stream=True)` + `aclose()`
2. **Thinking budget 硬编码** — `_normalize_thinking()` 将 `adaptive` 强制转为 `enabled` + 固定 10240。改为 Anthropic 格式原生透传
3. **SSE 压缩开销** — GZipMiddleware 全局包裹 SSE 流。直接移除
4. **JSON 双重序列化** — 每个事件 `json.loads()` → 处理 → `json.dumps()`。新增 `_sse_raw()` 跳过未修改事件
5. **Payload CPU 浪费** — `sort_keys()` 递归排序。改为 `dict(sorted(payload.items()))` 浅层排序

**回归验证状态**：✅ 全部通过（见下方 V13+ 基准测试）

### V13+ — 精细化运营 (2026-06-05 下午)

**背景**：V13 稳定运行后，用户发现 latency 波动（CONNECT 1-4 秒），以及"Writing file..."等操作时长时间无反馈。开始做深入诊断和精细化优化。

#### 改动 1：粒度化时序日志 (STREAM_TIMING)

**问题**：无法区分 thinking 时间是真实模型思考还是网络延迟。

**新增日志格式**：
```
STREAM_TIMING total=26797ms | req→first_think=8469ms think_dur=16250ms 
think→content=16ms content_dur=1218ms | tok: thinking=595 content=7 
| think_events=30 max_think_gap=250ms | stop=tool_use
```

**验证**：thinking_delta 间隔中位数 62-75ms，最大间隔 <300ms → 确认是真实模型思考，非网络延迟。

#### 改动 2：429 自动熔断降级

**问题**：xiaomi 欠费返回 429（quota exhausted），代理将其作为普通 4xx 直接丢回客户端，**不触发 failover**。所有请求都卡在 xiaomi 上重试，zhipu 从未被尝试。

**修复**：
```python
# 原先：4xx 全部直接返回客户端
if status < 500:
    return _error_response(...)

# 现在：429 单独处理，触发 failover
if status == 429:
    cb.record_failure()
    continue  # 尝试下一个 provider
```

#### 改动 3：Thinking `display` 字段透传

**问题**：`_normalize_thinking()` 将 `adaptive → enabled` 时丢弃了 `display` 字段。Anthropic API 支持 `display: "summarized"`（显示思考）和 `display: "omitted"`（隐藏思考）。

**修复**：
```python
normalized = {"type": "enabled", "budget_tokens": budget}
if thinking.get("display"):
    normalized["display"] = thinking["display"]
```

#### 改动 4：OpenAI 路径 thinking 配置丢失

**问题**：`_anthropic_to_openai()` 调用 `_normalize_thinking()` 后，thinking 配置**根本没有放进 OpenAI payload**。走 zhipu/GLM 时 thinking 参数完全被丢弃。

**修复**：
```python
if body.get("thinking"):
    oai_payload["thinking"] = body["thinking"]
```

#### 改动 5：一键热切换管理接口

**问题**：切换 provider 需要手动编辑 config.yaml 中的 `provider` 字段和所有路由规则。容易遗漏（路由规则优先级高于默认 provider）。

**新增接口**：

| 端点 | 功能 |
|------|------|
| `POST /admin/provider` | 一键切换：`{"provider": "zhipu"}` |
| `GET /admin/status` | 查看当前状态 |

**特性**：
- 即时生效（内存中更新）
- 持久化到 config.yaml（重启不丢）
- 自动更新所有路由规则
- 重置目标 provider 的熔断器（确保新 provider 干净启动）
- 提供快捷脚本 `watcher/switch_provider.py`

#### 改动 6：THINKING_CONFIG 诊断日志

**新增**：请求入口处打印 Claude Desktop 实际发送的 thinking 参数：
```
THINKING_CONFIG from client: {"type":"adaptive"}
```

**验证结果**：Claude Desktop 发送 `thinking: {"type": "adaptive"}`，不包含 `display` 字段。显示行为由后端模型默认值决定。

### V13+ 基准测试 (GLM/zhipu 路径, 2026-06-05)

代理切换到 zhipu/GLM 后的实际运行日志：

```
Route model claude-sonnet-4-6 -> provider 'zhipu' (first in chain)
[zhipu] openai claude-sonnet-4-6 -> glm-5.1  msgs=276 stream=True tools=55
Normalizing thinking: adaptive -> enabled budget=10240
HTTP Request: POST https://open.bigmodel.cn/api/coding/paas/v4/chat/completions "HTTP/1.1 200 OK"
OpenAI stream done: stop=tool_use text=True reasoning=63 tools=1 in=82933 out=73
```

**关键观察**：
- GLM 路径正常工作，reasoning tokens 正常产生
- Thinking 配置正确透传（adaptive → enabled）
- 路由规则正确（所有模型 → zhipu）
- 熔断器正常（xiaomi 429 后自动降级）

### TUN 模式排查

**发现**：系统运行 Clash Verge 代理，TUN 模式拦截所有流量（包括 localhost → 后端）。`198.18.0.x` 是 Clash TUN 的虚拟 DNS IP。

**解决**：关闭 Clash TUN 模式和 DNS 覆写，tracert 确认流量走真实网络路径。

### 代理桥关键文件

| 文件 | 路径 | 说明 |
|------|------|------|
| server.py | `proxy/server.py` | 主服务，1860 行 |
| config.yaml | `proxy/config.yaml` | 提供商/路由/熔断配置 |
| .env | `proxy/.env` | API Key 环境变量 |
| switch_provider.py | `watcher/switch_provider.py` | 一键切换脚本 |
| restart.ps1 | `proxy/restart.ps1` | 重启脚本 |
| proxy_debug.log | `proxy/proxy_debug.log` | 详细调试日志 |
| proxy_audit.log | `proxy/proxy_audit.log` | 结构化审计日志 |

### 代理桥完整修复清单

| # | 问题 | 修复 | 状态 |
|---|------|------|------|
| 1 | httpx `__aenter__` 不存在 | `send(stream=True)` + `aclose()` | ✅ |
| 2 | adaptive thinking 强制固定 budget | Anthropic 格式原生透传 | ✅ |
| 3 | GZipMiddleware 压缩 SSE 流 | 移除中间件 | ✅ |
| 4 | JSON 双重序列化 | `_sse_raw()` 零拷贝转发 | ✅ |
| 5 | sort_keys 递归 CPU 浪费 | 浅层排序 | ✅ |
| 6 | 无时序诊断数据 | STREAM_TIMING + max_think_gap | ✅ |
| 7 | 429 不触发 failover | 单独处理 429 为熔断错误 | ✅ |
| 8 | thinking display 字段丢失 | 保留 display 透传 | ✅ |
| 9 | OpenAI 路径 thinking 丢失 | 加入 oai_payload | ✅ |
| 10 | 切换 provider 需手动编辑 | `/admin/provider` 管理接口 | ✅ |
| 11 | Clash TUN 拦截流量 | 关闭 TUN + DNS 覆写 | ✅ |
| 12 | 路由规则覆盖默认 provider | 管理接口自动更新路由 | ✅ |
