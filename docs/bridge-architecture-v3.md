# Bridge 架构改进 V3 — Worker 健康与优雅关闭

## 背景

V22+ 回归测试发现 5 个缺陷，根因追溯揭示 5 个架构层面的系统性问题：

| # | 缺陷 | 架构根因 |
|---|------|----------|
| 1 | generic_1 pipe 不可达，每 6 命令出现 2s 尖峰 | 无 Worker 健康注册表 — 调度时盲目 round-robin |
| 2 | user_bridge 死透 5 天无人知 | 无统一 Worker 监控 — Guardian 遗漏 user_bridge |
| 3 | FSW 50ms 开销导致吞吐从 10.8→3.9 cmd/s | 单线程事件循环瓶颈 |
| 4 | Self-upgrade 杀 inflight 命令 | 无优雅关闭协议 |
| 5 | user 类型命令无降级路径，worker 死后卡死 | 路由无降级设计；重启后状态不持久化 |

## 改进方案

### P1.1 Worker 预检（Powershell, watcher/handlers/dispatch.ps1）

**设计：** dispatch 前快速检查目标 worker 的 pipe 是否可达。

```
function Test-WorkerPipeHealth($pipeName):
    try:
        pipe = Connect(pipeName, timeout=100ms)
        if connected: pipe.Close(); return true
    catch: return false
    return false
```

修改 `Dispatch-ToWorker` 函数：
- Connect 前先 Test-WorkerPipeHealth
- 失败则跳过此 worker，尝试下一个同类型 worker
- 记录 degraded 状态，下一次尝试不同 worker

### P1.2 Guardian 接管 user_bridge（Powershell, cluster/guardian_v3.ps1）

**设计：** Guardian 检查循环增加 user_bridge 健康检查。

```
function Invoke-CheckUserBridge:
    hb = Read(user_bridge/.heartbeat)
    if hb stale (>300s):
        lock_pid = Read(user_bridge/.lock)
        if lock_pid alive: kill it
        Remove user_bridge/.user_bridge_started
        Run user_bridge/runner.ps1
        Log "user_bridge restarted"
```

### P1.3 Inflight 持久化（Powershell, watcher/handlers/inflight.ps1）

**设计：** inflight 列表写入 `watcher/.inflight.json`，启动时恢复。

```
INFLIGHT_JSON = watcher/.inflight.json

function Add-Inflight:
    # existing logic...
    Save-InflightToDisk()

function Save-InflightToDisk:
    Write-Text(inflight_json, inflight | ConvertTo-Json)

function Restore-Inflight:
    if Test-Path(inflight_json):
        inflight = Read-Json(inflight_json)
        for each item:
            if result file exists: process result
            else: re-queue command
        Remove-Item(inflight_json)
```

### P2.1 Worker 健康注册表（Powershell, watcher/lib/common.ps1 + handlers/dispatch.ps1）

**设计：** 磁盘 + 内存双重 Worker 健康状态。

```
WORKER_HEALTH = watcher/.worker_health.json

结构:
{
    "generic_1": {
        "last_seen_healthy": "2026-06-08 10:31:53",
        "failure_count": 5,
        "degraded_at": "2026-06-08 10:28:00",
        "status": "degraded"  // healthy / degraded / dead
    },
    ...
}

function Update-WorkerHealth(id, status):
    entry = health_registry[id]
    if status == "healthy": entry.failure_count = 0; entry.degraded_at = null
    else: entry.failure_count++
         if entry.failure_count >= 3: entry.status = "degraded"
         if entry.failure_count >= 10: entry.status = "dead"
    Save-HealthRegistry()

function Get-HealthyWorker(type):
    candidates = workers where type matches AND status != "dead"
    sort by failure_count ASC, then round-robin
    return best candidate
```

### P2.2 命令路由降级（Powershell, watcher/handlers/dispatch.ps1）

**设计：** 主路径失败时自动降级到次路径。

```
路由表:
    user      → user_bridge (primary), generic (fallback)
    file      → file_* (primary), generic (fallback)
    wsl       → wsl_1 (primary), process (fallback)
    powershell → generic (primary), inline (fallback)
    cmd       → process (primary), generic (fallback)

function Dispatch-WithFallback(cid, ctype, cmd, timeout):
    primary = Get-PrimaryWorker(ctype)
    if primary and Test-WorkerPipeHealth(primary):
        return Dispatch-ToWorker(primary, cid, ctype, cmd, timeout)
    
    Log "[$cid] Primary $primary failed, trying fallback..."
    fallback = Get-FallbackWorker(ctype)
    if fallback and Test-WorkerPipeHealth(fallback):
        return Dispatch-ToWorker(fallback, cid, ctype, cmd, timeout)
    
    Log "[$cid] All workers failed, inline fallback"
    return Invoke-InprocessFallback(...)
```

### P2.3 Self-upgrade drain 协议（Powershell, watcher/handlers/self-upgrade.ps1）

**设计：** 重启前等待 inflight 完成，超时后 force-restart。

```
function Test-SelfUpgrade:
    # existing hash check...
    if hash changed:
        if Has-InflightCommands():
            Log "[SELF-UPGRADE] Waiting for $inflight.Count inflight commands..."
            Save-InflightToDisk()
        
        # Wait for inflight to drain (up to 30s)
        drain_start = Get-Date
        while Has-InflightCommands():
            if ((Get-Date) - drain_start).TotalSeconds > 30:
                Log "[SELF-UPGRADE] Drain timeout, forcing restart"
                break
            Start-Sleep -Milliseconds 500
        
        # Proceed with restart
        Write restart command...
```

### P3.1 双通道队列监视（Powershell, watcher/watcher.ps1）

**设计：** FSW 保持主通道，增加快速轮训从通道。

```
修改 main loop:

while ($true):
    # 1. FSW 通道（主，50ms 超时）
    $script:queueWatcher.WaitForChanged(Changed, 50)
    
    # 2. 快速轮训（每 5 次循环额外轮训一次）
    $script:pollCounter++
    if ($script:pollCounter % 5 -eq 0):
        $queue = Read-Json($queueFile)  # 无阻塞
    
    # 3. 处理 pending...
```

## 实施顺序

```
Phase 1 — 快速止血
  ├── P1.1 Worker 预检          → dispatch.ps1
  ├── P1.2 Guardian user_bridge  → guardian_v3.ps1
  └── P1.3 Inflight 持久化       → inflight.ps1

Phase 2 — 架构加固
  ├── P2.1 Worker 健康注册表     → common.ps1 + dispatch.ps1
  ├── P2.2 命令路由降级          → dispatch.ps1
  └── P2.3 Self-upgrade drain    → self-upgrade.ps1

Phase 3 — 性能优化
  └── P3.1 双通道队列监视        → watcher.ps1
```

## 测试计划

每个 Phase 完成后运行验证：

```
P1 验证:
  - 手动断开 generic_1 pipe, 确认 watcher 跳过它
  - Kill user_bridge 进程, 确认 Guardian 30s 内重启
  - 模拟 watcher 重启, 确认 inflight 恢复

P2 验证:
  - 标记所有 file worker 为 degraded, 确认 file 命令走 generic fallback
  - 触发 self-upgrade, 确认等待 inflight 完成

P3 验证:
  - 回归 benchmark, 确认吞吐恢复到 ~10 cmd/s
```
