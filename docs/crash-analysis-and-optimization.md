# Claude Bridge 崩溃分析与系统优化方案

> 分析时间: 2026-06-12 12:50
> 提交: 20cf161 (pool-sync), 5b7ecbc (bridge_client --fallback), a23444c (V3.1)

---

## 一、当前状态：全面失联，但 Worker 还在跑

### 组件存活表

| 组件 | 状态 | 最后活跃 | 说明 |
|------|------|----------|------|
| **Guardian** (v3) | 🔴 死亡 | 09:03:24 | 80,729 次历史检查后停止，counter 卡在 #1 |
| **Watcher** (V22+) | 🔴 死亡 | 10:15:00 | 日志轮转后无任何输出 |
| **Relay** | 🔴 死亡 | 10:56:31 | 最后转发 `read_agents` |
| **Bridge Agent** (:19850) | 🔴 死亡 | ~09:03 | TCP 连接超时 |
| **15 Workers** (generic/file/process/system) | 🟢 存活 | 12:50:05 | 心跳仍在写入，但父进程全挂了 |
| **Proxy** (:4000) | 🔴 死亡 | 09:03 | guardian 最后报告 alive 后失联 |

> 15 个 worker 进程变成孤儿——没人给它们派命令了。

### 守护链断裂

```
Guardian (scheduled task) ──看──→ Watcher ──管──→ Workers
         │                              │
         └── 也管 ──→ Bridge Agent / Relay / Proxy
```

问题：**Guardian 自己没人看**。它挂了之后，整条链断裂。

---

## 二、根因分析：5 个架构缺陷

### 缺陷 1: Guardian 没有自愈机制

Guardian 是 Windows Scheduled Task，运行 `guardian_v3.ps1`。日志显示它 6 月 8 日以来跑了 80,000+ 次，但最后停在 09:03，counter 始终显示 `#1`（正常应递增）——说明它每次运行都被当作"第一次"，可能每次启动新进程而非保持状态。

**后果**: Guardian 一旦退出，没有任何机制把它拉起来。Watcher 没人监控，Watcher 死了也没人重启。

### 缺陷 2: 四层中间件无意义堆积

```
Claude ──→ Write queue.txt ──→ Relay ──→ Watcher ──→ Workers
               │  9P cache        │FSW       │FSW+pipe
               │  delay 5-30s     │          │
               └── TCP bridge ────┘          │
                   :19850                     │
                     (Phase 3 bypass)         │
                                              │
                     Named Pipe (broken) ─────┘
                     Subprocess fallback ─────┘
```

**同一台机器（Windows）上有 4 种通信机制**:
1. **queue.txt** - 通过 9P 文件系统，有 5-30s 延迟
2. **relay** - 转发根 queue → watcher queue，增加一层复杂性
3. **Named Pipe** - 6 个 generic pipe 全部超时，形同虚设
4. **TCP bridge** - 唯一无 9P 缓存的通道，但 bridge_agent 也死了

**问题**: Relay 在 Watcher 同一台机器上转发文件内容——纯粹多一层。如果直接写 `watcher\queue.txt`，根本不需要 relay。

### 缺陷 3: 9P 文件系统读缓存未解决（已知但未完全修复）

即使队列文件写入 Windows 端成功（通过 Write 工具触达 D: 盘），但：
- **从 VM 读**：返回的是几秒前的缓存内容（~70 bytes vs 实际 ~55KB 的 JSON）
- **从 Windows 读**：内容是新的

V3 做的 TCP bridge 可以绕过写缓存问题，但 TCP bridge 本身依赖 bridge_agent 存活——bridge_agent 挂了就没用了。

### 缺陷 4: Worker Named Pipe 全部不可用

6 个 generic worker 的 Named Pipe 从创建（6 月 10 日）起就一直无法连接。`NamedPipeClientStream.Connect(300)` 全部超时。虽然不是阻塞性问题（subprocess fallback 完美工作，72-99ms），但：
- 每条命令都多一个 300ms 超时周转
- log 里全是 `pipe unresponsive — skipping` 噪音
- 最后所有 generic worker 在 health registry 里都是 `degraded` 或 `dead`

### 缺陷 5: 组件之间无心跳同步

- Guardian 检查 watcher 是否 alive，但 watcher 不检查 guardian
- Watcher 读 pool 文件，但不写确认信号
- Bridge agent TCP 监听没有保活机制
- 组件死亡时，没有任何组件收到通知

---

## 三、优化方案：3 阶段改造

### Phase A: 稳定守护链（最紧急）

**目标**: Guardian 死后能自动恢复

```
+------------------------------------------------------------------+
| Windows Scheduled Task (每分钟)                                    |
|   └─→ guard-dog.ps1                                               |
|         ├─→ 检查 Guardian PID 文件是否存在                          |
|         ├─→ 如果 Guardian 死亡 → 启动新 Guardian 实例              |
|         └─→ 检查 Watcher 心跳文件 → 过期则重启                     |
|                                                                   |
| Guardian v3                                                       |
|   ├─→ 检查 Watcher alive? → 否 → 重启 watcher.ps1                |
|   ├─→ 检查 Bridge Agent alive? → 否 → 启动 bridge_agent.py       |
|   ├─→ 检查 Worker pool 健康 → 清理死 PID                          |
|   ├─→ 检查内存压力 → 告警 / 收缩                                  |
|   └─→ 写 Guardian 心跳文件 → guard-dog 读取                       |
+------------------------------------------------------------------+
```

**具体改动**:
1. 新建 `cluster/guard-dog.ps1` — 极简脚本，由 Scheduled Task 每分钟触发
2. 只做一件事：检查 Guardian 是否活着（PID file / heartbeat），如果死了就启动它
3. Guardian 每次健康检查后写时间戳到 `.guardian_heartbeat`

### Phase B: 精简通信通道（中期）

**目标**: 消除 relay，统一通信路径

```
Before:                      After:
Claude ──→ queue.txt ──→ Relay ──→ watcher\queue.txt ──→ Watcher
                                                                ↓
Claude ──→ TCP bridge ──→ Bridge Agent ──→ CallNamedPipe ──→ Workers
                          (:19850)        (或 queue.txt fallback)
```

**具体改动**:
1. 移除 relay.ps1（不再需要）
2. Watcher 改为纯 TCP 监听模式，增加 `--tcp` 模式在 :19851 监听命令
3. Bridge client 默认走 TCP，9P 文件写只做 fallback
4. Bridge agent 和 watcher 合并或紧密耦合

### Phase C: Worker Pipe 修复 + 内存管理（长期）

**目标**: Named Pipe 正常运作，消除 memory pressure 导致的级联崩溃

1. **Worker pipe 定期回收**: Guardian 每 5 分钟测试 worker pipe，连续 3 次失败 → 重启 worker
2. **内存压力自动缓解**: 当 free < 5% 时，Guardian 主动关闭低优先级 worker（类型 file/process 从 2→1，system 从 1→0）
3. **Worker 上线上限**: 根据当前可用内存动态计算 worker 数量
4. **旧 worker 轮换**: 超过 24 小时的 worker 逐个重启（rolling restart）

---

## 四、遗留的 P0 级 Bug（已修复）

以下 bug 已通过 `20cf161` 和 `5b7ecbc` 修复，记录在此供规则引擎参考：

### Pool-sync PSCustomObject → Hashtable（V2.4~V3.1 范围）
- **日志确认**: `[WARN] Worker pool sync error (non-fatal): 只能将哈希表添加到另一个哈希表中`
- **根因**: PS 5.1 中 `ConvertFrom-Json` 返回 PSCustomObject，`@{} + $w` 永远失败
- **影响**: 自 V2.4 以来 pool 文件从未被 Sync-WorkerPool 更新过，仅靠 worker_factory 初始写入
- **连带 Bug**: `last_heartbeat` 因 `if (-not $pidDelta) { return }` 永不持久化
- **修复**: `_ConvertTo-Hashtable` 函数 + 心跳变化检测

### bridge_client.py --fallback 参数顺序
- **症状**: `--fallback '{"command":"..."}'` 中 `args[0]` 是 `--fallback` 而非 JSON
- **修复**: 过滤 `--` flags 后取第一个 positional arg

---

## 五、核心指标

| 指标 | 值 |
|------|-----|
| Worker 连续运行时间 | 2 天 21 小时 (6/10 15:30 → 至今) |
| Guardian 历史检查次数 | 80,729 次 |
| 最后全部健康 | 2026-06-12 09:03 |
| 崩盘时间窗口 | 09:03 → 10:56 (约 2 小时逐级死亡) |
| 内存崩溃时 | 3.6% free (11:26:35)，后回升至 6-14% |
| 当前 Git HEAD | `5b7ecbc` (bridge_client --fallback) |
