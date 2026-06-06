# V18 Modules 复用价值索引

> 日期：2026-06-06 | 总指挥对话产出
> 目的：标注 V18 modules/ 目录每个模块与 V21 watcher.ps1 的对应关系，
> 以及 TCP Phase 3（bridge_agent.py 直连 Named Pipe）时的参考价值。

---

## 总览

| 模块 | 行数 | V21 对应 | Phase 3 价值 | 状态 |
|------|------|---------|-------------|------|
| bridge-core.ps1 | 118 | watcher.ps1 L58-103 (helpers) | 低 — 通用工具 | 需要更新 |
| queue-monitor.ps1 | 113 | watcher.ps1 L120-180 (FSW) | 无 — Phase 3 跳过 queue | 已不相关 |
| command-executor.ps1 | 140 | worker_generic.ps1 (ScriptBlock) | 无 — 执行在 worker 端 | 已不相关 |
| **pipe-dispatcher.ps1** | **171** | watcher.ps1 L430-474 (Dispatch-ToWorker) | **高 — Named Pipe 协议参考** | **可直接参考** |
| safety-guard.ps1 | 106 | watcher.ps1 L284-350 (dedup/inflight) | 中 — 逻辑可复用 | 需要更新 |
| result-collector.ps1 | 84 | watcher.ps1 内联 (Write-Result) | 中 — 结果格式参考 | 可直接参考 |
| error-learner.ps1 | 95 | cluster/rule_engine.ps1 V5 | 低 — 规则引擎已独立 | 已不相关 |
| process-guard.ps1 | 119 | Guardian v3 + watcher 自升级 | 低 — 已被 Guardian 替代 | 已不相关 |

---

## 详细分析

### 1. pipe-dispatcher.ps1 — ★ 最高价值

**导出函数：**
- `Send-ViaPipe(WorkerName, CmdJson)` — Named Pipe 客户端连接+发送
- `Send-ToWorker(Channel, Command, CmdId, Type, TimeoutSec)` — 高层分发入口
- `Get-WorkerChannels()` — 获取可用 worker 通道列表
- `Get-AliveWorkers()` — 探测哪些 worker 管道在线

**V21 对应：** watcher.ps1 L418-474 (`Get-WorkerPool`, `Get-WorkerForType`, `Dispatch-ToWorker`)

**Phase 3 关键参考：**
```
管道名称格式: Cluster_Wkr_{type}_{n}
连接: NamedPipeClientStream(".", pipeName, InOut)
超时: 200ms Connect
协议: WriteLine(CmdJson) → ReadLine(ResultJson)
命令 JSON: {"id":"cmd_id","c":"command","t":"type","to":timeout}
结果 JSON: {"id":"cmd_id","e":exit_code,"o":"stdout","s":"stderr","err":"error","d":duration_ms}
```

**注意：** V21 改用了异步模型（发命令→立即 ACK→worker 异步写 `r_{cid}.json`→watcher 轮询结果）。bridge_agent.py Phase 3 应该用 V21 的异步模式，不是 V18 的同步请求-响应。

**Python 翻译指引：**
```python
# V18 pipe-dispatcher 的 PowerShell 协议 → Python asyncio
import asyncio

async def send_via_pipe(pipe_name: str, cmd_json: str, timeout: float = 0.2):
    # Windows Named Pipe 在 Python 中需要 win32pipe 或 socket 间接访问
    # 推荐方案：bridge_agent.py 用 subprocess 调用一小段 PowerShell
    #   或者用 pywin32 的 win32pipe.CallNamedPipe
    pass
```

---

### 2. result-collector.ps1 — 结果格式参考

**导出函数：**
- `Write-Result(CmdId, ExitCode, Stdout, Stderr, ErrorMsg, DurationMs, WasFastPath)` — 写入 r_{cid}.json
- `Clean-StaleResults()` — 清理过期结果文件
- `Read-Result(CmdId)` — 读取结果

**V21 对应：** watcher.ps1 内联的结果写入逻辑

**Phase 3 参考：** 结果 JSON 格式需要与现有 Claude 客户端代码（Write tool 写 queue.txt + Read tool 读 r_{cid}.json）完全兼容。

**结果格式（必须保持）：**
```json
{
  "state": "done",
  "cmd_id": "xxx",
  "exit_code": 0,
  "stdout": "...",
  "stderr": "",
  "error": "",
  "duration_ms": 123,
  "timestamp": "2026-06-06 10:00:00"
}
```

---

### 3. safety-guard.ps1 — dedup + inflight

**导出函数：**
- `Try-ReuseDedupResult(CmdText, CmdId)` — 内容去重
- `Test-Inflight()` — 检查是否有命令在执行中
- `Set-Inflight(CmdId)` / `Clear-Inflight()` — 设置/清除 inflight 状态
- `Add-Dedup(CmdText, CmdId)` — 添加去重条目

**V21 对应：** watcher.ps1 L284-350 — V21 版本更完善（增加了 inflight timeout、inflight count tracking、inflight results polling）

**Phase 3 参考：** bridge_agent.py 也需要 dedup 和 inflight guard。但应该参考 V21 的版本（带 timeout），不是 V18 的。

---

### 4. bridge-core.ps1 — 通用工具

**导出函数：**
- `Write-BridgeLog(Message)` — 日志（带 fallback）
- `Write-File(Path, Content)` — 原子文件写入
- `Read-Json(Path)` — JSON 读取（带重试）
- `Read-Queue()` — 读队列文件
- `Write-Heartbeat()` — 写心跳
- `Acquire-Lock()` / `Release-Lock()` — PID 锁
- `Clean-Progress(CmdId)` — 清理进度文件

**V21 对应：** watcher.ps1 L58-103 的 `Write-Text`, `Read-Json`, `Log` 函数

**Phase 3 参考：** Python bridge_agent 不需要这些 PowerShell 工具。但日志、心跳、锁的设计模式可以参考。

---

### 5. V18 有但 V21 没有的功能

1. **`__BRIDGE_STATUS__` 元命令** — V18 pipe-dispatcher 里有桥状态报告（worker 数量、通道列表）。V21 没有这个。bridge_agent.py 可以加入类似的 `/status` 命令。
2. **文件队列 fallback 链** — V18 pipe-dispatcher 在 Named Pipe 失败时 fallback 到写 worker 目录的 queue.txt。Python bridge_agent 可以用类似的 fallback。

---

### 6. V21 有但 V18 没有的功能（Phase 3 必须考虑）

1. **异步 dispatch + inflight tracking** — V21 发命令后立即返回 ACK，worker 异步写结果，watcher 轮询 `r_{cid}.json`。bridge_agent.py Phase 3 需要实现类似逻辑。
2. **Worker pool JSON 发现** — V21 从 `.worker_pool.json` 读 worker 列表和 pipe 名称。bridge_agent.py 必须读同一个文件。
3. **按类型轮询分发** — V21 `Get-WorkerForType` 按 worker 负载选择最空闲的 worker。
4. **Guardian 维护** — V21 主循环里有 Guardian scheduled task 健康检查。
5. **HostLoopMode 清理** — V21 每 60 秒清理 session JSON 里的 WSL 路径。
6. **自升级检测** — V21 检测 watcher.ps1 文件变化并触发重启。

---

## Phase 3 实现指引（给 bridge_agent.py）

基于以上分析，bridge_agent.py Phase 3 的关键设计点：

1. **读取 `.worker_pool.json`** 获取 worker 列表（复用 V21 的 pool 文件格式）
2. **Named Pipe 协议** 参考 V18 pipe-dispatcher.ps1，但用 **V21 异步模式**：
   - 发送命令 JSON 到 worker 的 Named Pipe
   - 等待 ACK（worker 确认收到）
   - 轮询 `r_{cid}.json` 等待完整结果
   - 通过 TCP 响应返回给沙箱客户端
3. **Fallback** — Named Pipe 失败时回退写 queue.txt（参考 V18 fallback 链设计）
4. **结果格式** — 必须与 `r_{cid}.json` 格式完全兼容（参考 result-collector.ps1）
