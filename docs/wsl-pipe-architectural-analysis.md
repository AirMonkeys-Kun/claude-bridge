# WSL 管道延迟实验 + 架构分析

## 一、实验结论：超时不是问题

2026-06-12 对 18 个 WSL 命令的实测数据：

| 指标 | 数值 |
|------|------|
| P50 管道直连延迟 | **85ms** |
| 平均延迟 | 96ms |
| Min | 72ms |
| Max（短命令） | 216ms |
| 管道连接失败率 | **11.1%**（2/18）|

核心结论：**bridge_agent 的 PIPE_TIMEOUT_MS = 150 不需要加长。** WSL 命令不是直接连接 WSL 管道，而是通过 generic worker（本地进程）中转，管道连接 <10ms。150ms 绰绰有余。

---

## 二、真正的问题架构图

```
                      ┌──────────────────────────────┐
                      │      Cowork / 外部客户端       │
                      └──────────┬───────────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
      ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
      │  bridge_agent │  │    Relay     │  │  root queue  │
      │  (TCP :19850) │  │  (file fwd)  │  │  queue.txt   │
      └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
             │                 │                  │
             │           ┌─────▼──────┐           │
             │           │  Watcher   │◄──────────┘
             │           │queue+FSW   │
             │           └─────┬──────┘
             │                 │
             ▼                 ▼
      ┌──────────────┐  ┌──────────────┐
      │  Pool File   │  │  Workers     │
      │.worker_pool  │  │generic_1..6  │
      │     .json    │  │wsl_1, etc.   │
      └──────────────┘  └──────┬───────┘
                               │
                        ┌──────▼───────┐
                        │  WSL (Ubuntu)│
                        │  commands    │
                        └──────────────┘
```

### 问题 1：双调度路径共享同一组 worker

- **bridge_agent** 通过 Named Pipe 直连 worker（CallNamedPipe）
- **Watcher** 也通过 Named Pipe 分发到同一个 worker（NamedPipeClientStream）
- 两者共享 `.worker_pool.json`，但**无互斥/同步机制**
- worker 同时只能处理一个命令（单个 pipe server instance）
- 当 bridge_agent 和 watcher 同时分发，worker 忙 → pipe connect 超时

### 问题 2：Worker PID 同步失效

Watcher 在 `pool-sync.ps1` 中定期生成 `.worker_pool.json`，包含 worker PIDs。
bridge_agent 在 `pool.py` 中缓存此文件（30s TTL），调用 `is_pid_alive()` 过滤。

**当 watcher 重启 worker（新 PID）时：**
1. Watcher 更新 `.worker_pool.json` ✓
2. Bridge agent 缓存未过期（<30s）→ 使用旧 PID ✓（可能还活着）
3. 但 watcher 杀旧 worker 启动新 worker → 旧 PID 死 → `is_pid_alive()` 过滤掉
4. Bridge agent 找不到可用 worker → fallback 到 queue.txt

这个 gap 解释了为什么 bridge_agent 日志中 WSL 命令全部 fallback 到 queue。

### 问题 3：Dispatch 超时不一致

`watcher/handlers/dispatch.ps1` 中有两处超时：

| 位置 | 函数 | 超时 | 类型 |
|------|------|------|------|
| 行 22 | `Test-WorkerPipeHealth` | 2000ms(WSL) / 100ms(其他) | **自适应** |
| 行 164 | `Dispatch-ToWorker` | **300ms 硬编码** | **固定** |

`Test-WorkerPipeHealth` 是预检（ping），真正分发时用的是 `Dispatch-ToWorker` 的 300ms。
两者不一致导致：预检通过 → 分发却超时。

### 问题 4：内存压力（系统级风险）

日志显示内存剩余持续 **6-9%**（32GB 总量，约 2-3GB 空闲）。
每 10-15 秒出现一次 `[MEMORY] WARNING`。

内存压力对管道超时的影响：
- worker 进程被分页到磁盘 → 响应延迟
- pipe server instance 切换变慢 → Connect 超时概率上升
- 解释了 ~11% 的间歇性管道失败

---

## 三、架构优化方向

### 优化 A：消除双调度路径

**现状：** bridge_agent + watcher 都直接分发到 worker，靠 queue.txt 作为唯一的同步点。

**方案：** bridge_agent 不再直连 worker，统一走 watcher 分发。
- bridge_agent TCP 收到命令 → 写入 queue.txt
- watcher 从 queue 读取 → 分发到 worker
- 移除 bridge_agent 中的 `dispatch_via_pipe()`、`_pipe_win32()`、worker pool 缓存

**代价：** 增加一次文件 I/O（但实测 watcher 分发 WSL 只需 85ms，比 pipe 的 72ms 多 ~13ms，可接受）

### 优化 B：统一超时策略

**现状：** 三处超时互相独立

| 模块 | 超时值 | 位置 |
|------|--------|------|
| bridge_agent/config.py | 150ms | `CallNamedPipe` |
| modules/pipe-dispatcher.ps1 | 200ms | `$pipe.Connect(200)` |
| watcher/dispatch.ps1 | 100/2000ms + 300ms | Test + Dispatch |

**方案：** 统一到一个配置点，按 worker type 自适应：
- generic / system / file / user：**100ms** connect（本地进程，<10ms 实际连接）
- wsl worker：**2000ms**（如果 wsl worker 存在，WSL interop 360-430ms）
- 但当前 wsl worker 已死，WSL 走 generic，所以 100ms 就够了

### 优化 C：Worker pool 单一事实源

**现状：** 
1. Watcher 在 `pool-sync.ps1` 维护 worker pool
2. Bridge agent 在 `pool.py` 独立缓存一份（30s TTL）
3. Worker 心跳（`.heartbeat` 文件）由 watcher 维护

**方案：** 
- 移除 bridge_agent 的 pool 缓存，每次分发直接从 `.worker_pool.json` 读取
- 或者 bridge_agent 直接查询 watcher 的内存状态（通过 Named Pipe 发送状态查询命令）
- worker_pool.json 应包含 `last_heartbeat` 字段（不仅 PID），让 reader 能判断 worker 是否活的

### 优化 D：解决 11% 的管道间歇失败

**现状：** `Dispatch-ToWorker` 使用 `$pipe.Connect(300)`，当 worker 忙碌时超时。

**方案：** 
- 增加重试机制：300ms 超时后等待 50ms 重试另一个 worker
- 或增加 pipe server instance 数量（当前 worker 默认 1 个 NamedPipeServerInstance）
- 或让 worker 在命令间隙保持 pipe 监听（防止 instance 被 GC）

### 优化 E：内存压力缓解

- 对 `[MEMORY] WARNING` 添加自动响应：清理临时文件、重启非关键 worker
- Guardian 添加内存监控阈值：<10% 时触发 worker 缩减
- 减少同时存活的 worker 数量（当前 generic_1-6 + system_1-2 + ... = 15+ workers）

---

## 四、与过去错误的关联

| 过去的问题 | 关联发现 |
|-----------|---------|
| OOM 级联崩溃 | 内存 6-9% 持续低位，仍然是底层风险 |
| watcher.log 静默停写 | 日志轮转已修复，但内存不足时可能再次触发 |
| 信号灯超时错误 | 与当前 11% 管道超时同类问题，根源是 worker 资源争抢 |
| 去重 Bug | 双调度路径下重复分发仍未完全消除风险 |
| Named Pipe 启动死锁 | 管道竞争条件在所有组件共享同一组 worker 时持续存在 |
| Worker PID 锁替换为 Mutex | 但 pool 同步仍然基于文件（9P 缓存问题） |

## 五、推荐优先顺序

1. **优化 D + 优化 C**（低风险、高收益）：统一 pool 来源 + 给 Dispatch-ToWorker 加重试
2. **优化 A**（架构简化）：消除双调度路径，bridge_agent 只走 queue
3. **优化 B**（一致性）：统一超时配置
4. **优化 E**（内存）：Guardian 增强，但需谨慎防递归
