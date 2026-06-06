# Claude Bridge 架构白皮书

> 版本：V1.0 | 日期：2026-06-06
>
> 站在架构师和顶级编程专家的角度，对所有会话成果的系统整合。
> 本文档是通信桥的单一权威参考，替代所有零散的会话记忆和阶段文档。

---

## 目录

1. [系统总览](#1-系统总览)
2. [通信桥架构（当前）](#2-通信桥架构当前)
3. [演进史：从 V1 到 Phase 3 的教训](#3-演进史从-v1-到-phase-3-的教训)
4. [9P 缓存问题与解决方案](#4-9p-缓存问题与解决方案)
5. [自愈体系](#5-自愈体系)
6. [命令分发流程（完整路径）](#6-命令分发流程完整路径)
7. [代理桥参考](#7-代理桥参考)
8. [关键决策记录](#8-关键决策记录)
9. [运行状态与验证](#9-运行状态与验证)
10. [未来方向](#10-未来方向)

---

## 1. 系统总览

### 1.1 双桥架构

Claude 在 Cowork 沙箱中通过两座桥突破能力边界：

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Cowork Desktop                                  │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │  Linux VM (172.16.10.3) — bwrap, virtiofs, tap0                  │   │
│  │                                                                   │   │
│  │  ┌──────────┐              ┌─────────────────┐                   │   │
│  │  │ 代理桥    │              │  通信桥          │                   │   │
│  │  │ HTTP     │              │  TCP :19850      │                   │   │
│  │  │ server.py│              │  bridge_client   │                   │   │
│  │  └────┬─────┘              └────────┬─────────┘                   │   │
│  └───────┼─────────────────────────────┼─────────────────────────────┘   │
│          │ HTTP via tap0               │ TCP 0.8ms                      │
└──────────┼─────────────────────────────┼─────────────────────────────────┘
           ▼                             ▼
┌──────────────────┐    ┌──────────────────────────────────────────────┐
│ xiaomi / zhipu    │    │ Windows Host                                 │
│ AI 后端           │    │                                              │
└──────────────────┘    │  bridge_agent.py (:19850)                     │
                        │    ├── Named Pipe → Worker (Phase 3, 17ms)    │
                        │    └── queue.txt → watcher (fallback)         │
                        │                                              │
                        │  watcher.ps1 (V22) + Guardian v3              │
                        │  worker_factory + 14 workers                  │
                        └──────────────────────────────────────────────┘
```

### 1.2 两个桥的职责边界

| 维度 | 代理桥 | 通信桥 |
|------|--------|--------|
| 用途 | AI 对话推理 | 执行宿主机命令 |
| 协议 | HTTP (Anthropic Messages API) | TCP → Named Pipe / queue.txt |
| 端口 | 4000 (localhost) | 19850 (跨 VM) |
| 后端 | xiaomi/zhipu | Windows 进程/文件/服务 |
| 代码 | ~1970 行, `proxy/server.py` | ~2700 行, 跨 10+ 文件 |
| 状态 | 稳定，无需重构 | 已稳定，需维护 |

### 1.3 沙箱网络拓扑

```
Linux VM (Cowork Sandbox)
  bwrap: --dev-bind / / --proc /proc --unshare-pid --die-with-parent
  (--unshare-net 已移除，沙箱有完整网络能力)

  ├── tap0: 172.16.10.3/24     ← 真实网络，直连宿主机 0.8ms RTT
  ├── Gateway: 172.16.10.1     ← 默认网关
  ├── Proxy: 172.16.10.254:7897 ← HTTP/HTTPS 代理
  ├── virtio-serial "claude-daemon-console" ← RPC
  └── virtiofs ← 文件共享 (outputs/uploads/memory/skills)
```

---

## 2. 通信桥架构（当前）

### 2.1 组件清单

| 组件 | 位置 | 语言 | 职责 | 行数 |
|------|------|------|------|------|
| bridge_agent.py | `bridge_agent.py` | Python | TCP 服务端 :19850, Named Pipe 分发, watcher watchdog | ~270 |
| bridge_agent/config.py | `bridge_agent/config.py` | Python | 路径、常量、共享状态 | ~30 |
| bridge_agent/pool.py | `bridge_agent/pool.py` | Python | Worker pool 加载 + Windows PID 检测 | ~80 |
| bridge_agent/dispatch.py | `bridge_agent/dispatch.py` | Python | Pipe 分发、queue fallback、结果轮询 | ~130 |
| bridge_client.py | `bridge_client.py` | Python | 沙箱端 TCP 客户端，queue.txt fallback | ~140 |
| watcher.ps1 | `watcher/watcher.ps1` | PowerShell | 主循环调度、9 个 handler、自升级 | ~920 |
| restarter.ps1 | `watcher/restarter.ps1` | PowerShell | 自包含重启器，零外部依赖 | ~50 |
| guardian_v3.ps1 | `cluster/guardian_v3.ps1` | PowerShell | 看守器（当前为备份层） | ~250 |
| worker_factory.ps1 | `cluster/worker_factory.ps1` | PowerShell | 按类型创建 workers，-DeployAll 原子部署 | ~200 |
| BridgeCommon.psm1 | `modules/BridgeCommon.psm1` | PowerShell | Write-SafeFile, Write-Heartbeat, Read-SafeJson | ~120 |
| BridgeExecution.psm1 | `modules/BridgeExecution.psm1` | PowerShell | 执行引擎（ScriptBlock 快路径 + 子进程） | ~180 |
| BridgeRules.psm1 | `modules/BridgeRules.psm1` | PowerShell | 规则引擎、错误学习、Log-ExecutionError | ~400 |

### 2.2 数据流（主路径）

```
沙箱 (VM)                                     Windows 宿主
───────                                        ────────────
Claude Agent
  │
  │ bridge_client.py {'command': 'dir', ...}
  │
  ├── TCP 127.0.0.1:19850 (socket)
  │                ↓                          bridge_agent.py
  │                                    ┌─────────────┼─────────────┐
  │                                    │             │             │
  │                              Named Pipe    Named Pipe    queue.txt
  │                              generic_1     generic_2    (fallback)
  │                                    │             │             │
  │                              worker 执行  worker 执行   watcher.ps1
  │                                    │             │      → Named Pipe
  │                                    ▼             ▼         → worker
  │                              r_cmd.json    r_cmd.json    r_cmd.json
  │                                    │             │             │
  │  TCP 响应 ←───────────────────────┴─────────────┴─────────────┘
  │  {state:"done", exit_code:0, stdout:"...", ...}
  │
  └── (回退) Write queue.txt → python3 fsync → 轮询 r_cmd.json
```

### 2.3 Worker 类型分布

| 类型 | 数量 | 管道名 | 用途 |
|------|------|--------|------|
| generic | 6 | `Cluster_Wkr_generic_{1-6}` | cmd/powershell 通用命令 |
| file | 4 | `Cluster_Wkr_file_{1-4}` | 文件读写操作 |
| process | 2 | `Cluster_Wkr_process_{1-2}` | 进程管理 |
| system | 2 | `Cluster_Wkr_system_{1-2}` | 系统服务/注册表 |
| wsl | 1 | `Cluster_Wkr_wsl_1` | WSL 命令 |
| user | 1 | `Cluster_Wkr_user_1` | 用户上下文命令 |

**并发模型**：Round-robin 跨同类型 worker，3 次重试，CallNamedPipe timeout=0 (非阻塞)

### 2.4 性能基准（2026-06-06 实测）

| 指标 | queue.txt 旧方案 | TCP + Pipe 新方案 | 改善 |
|------|-----------------|-------------------|------|
| Echo avg | 195ms | **17ms** | **11.5x** |
| Echo p50 | 204ms | **16ms** | **12.8x** |
| Echo p99 | 211ms | **41ms** | **5.1x** |
| 10 并发成功率 | 2/10 (concurrent queue corruption) | **10/10** | 修复 |
| 10 并发 wall time | ~30s | **794ms** (12.6 cmd/s) | **37x** |
| Worker 故障容忍 | 无 | 自动跳过死 worker, 16ms 恢复 | 新增 |

---

## 3. 演进史：从 V1 到 Phase 3 的教训

### 3.1 完整时间线

```
2026-06-01        2026-06-04            2026-06-05         2026-06-06
───────           ──────────            ──────────         ──────────
V1 (queue.txt 诞生)   V16 (规则引擎)       V13+ (代理桥)      Phase 3 TCP
V2 (stdout 截断)      V17 (ScriptBlock)   代理精细化运营      V22 重构
V3 (多行修复)         V18 (9P 缓存 + Pipe)                   记忆整合
V4 (ReadToEndAsync)   V19 (Pipe 集成)                       本架构文档
                      V20 (Worker 工厂)
                      V21 (async + 自愈)
                      V22 (extracted handler)
```

### 3.2 每个版本的核心教训

| 版本 | 承诺 | 实际发现 | 架构教训 |
|------|------|---------|---------|
| V1-V4 | 通信桥可用 | stdout 截断需 ReadToEndAsync + WaitForExit + task.Result 三者缺一不可 | .NET 异步 I/O 不是直觉性的 |
| V16 | 规则引擎 | cmd-pipe-escape, python-utf8-encoding 等规则自动解决问题 | 命令变换层是必要抽象 |
| V17 | ScriptBlock 快路径 | 进程内执行 10ms vs 子进程 150ms, 15x 加速 | 纯 PowerShell 命令应走快路径 |
| V18 | 9P 缓存修复 | 唯一文件名绕过读缓存 200ms→25ms | **9P FUSE 不可信任** |
| V19 | Named Pipe 分发 | Pipe 比 FSW 更快更可靠 | IPC 通道优于文件 |
| V20 | Worker 工厂 | -DeployAll 原子部署消除 file_1 竞态 | 串行写共享状态是 bug 源 |
| V21 | Async + 自愈 | inflight 跟踪 + 三层自愈体系 | 系统必须能自我修复 |
| V22 | Handler 提取 | 383 行主循环 → 9 个命名函数 | 长函数隐藏回归风险 |
| Phase 3 | TCP 桥 | 17ms 往返, 完全绕过 9P 缓存 | **网络通道优于文件共享** |

### 3.3 修复循环的元模式

今天跨 19 个会话反复出现的模式：

```
架构师意图：重构到生产级
    ↓
发现 A 问题 → 修复 A
    ↓
发现 B 问题（被 A 掩盖的更深处）→ 修复 B
    ↓
发现 C 问题（被 B 掩盖）→ 修复 C
    ↓
...递归发现 9P 缓存 → TCP 桥 → V22 regression → 记忆过期
    ↓
今天终点：记忆整合 + 架构文档化
```

**根因**：系统复杂度超过单次重构能覆盖的范围。每次修到当前层，发现下一层还有问题。这个递归不是"失败的"，而是**深度问题需要深度解决**的自然过程。

---

## 4. 9P 缓存问题与解决方案

### 4.1 问题本质

Claude 沙箱通过 virtiofs (Plan 9 协议) 访问宿主文件系统。9P FUSE 客户端默认启用 write-back caching：

| 缓存类型 | 表现 | 延迟 |
|---------|------|------|
| **写缓存** | VM 写入 queue.txt 后 5-30s Windows 才看到 | 5-30s |
| **读缓存** | VM 重复读相同文件名返回旧数据 | 200-600ms |
| **写撕裂** | 文件存在但内容不完整（元数据先于内容到达） | — |

### 4.2 三层解决方案

| 层 | 问题 | 方案 | 效果 |
|----|------|------|------|
| **读缓存** | 重复读旧数据 | V18 唯一文件名 `r_{cid}.json` | <25ms, 穿透缓存 |
| **写撕裂** | 读到部分内容 | Write-SafeFile temp+rename 原子写 | NTFS 同卷 rename 原子性 |
| **写缓存 (queue.txt)** | Windows 侧看不到写入 | TCP 桥完全绕过 9P 文件系统 | 0.8ms RTT，零缓存 |

### 4.3 核心规律

```
Windows 进程写入的文件 → 无缓存问题 ← bridge_agent, watcher, heartbeat
VM 侧（9P）写入的文件 → 有缓存问题 ← Write tool, bash 写 queue.txt
```

**一切问题源于**：VM 对 9P 挂载目录的写操作不是即时可见的。TCP 通道完全绕过文件系统，是唯一的干净解决方案。

### 4.4 决策树

```
需要向 watcher/worker 提交命令
  │
  ├─ 从 VM 侧 (Claude 沙箱)
  │    ├─ ✓ TCP 可用 → bridge_client.py TCP（推荐，17ms，无缓存）
  │    └─ TCP 不可用 → queue.txt + Python os.fsync(f.fileno())
  │
  ├─ 从 Windows 侧 (PowerShell 脚本)
  │    └─ Write-SafeFile（Windows 侧不受 9P 影响）
  │
  └─ 从 VM 侧读结果 → r_{cmd_id}.json（唯一文件名，<25ms）
```

---

## 5. 自愈体系

### 5.1 四层架构

```
Layer 0: bridge_agent 内置 watchdog  ← 新增（本对话）
  ├── Python 线程，每 60s 检查 watcher 心跳
  ├── 心跳 stale 120s → 移除锁文件 → 启动 restarter
  ├── 比 Guardian Scheduled Task 更稳定（无 PS host 崩溃/S4U 问题）
  └── 使用 subprocess.Popen 启动 restarter (CREATE_NO_WINDOW)

Layer 1: Guardian v3（Scheduled Task） ← 原始外层
  ├── 注册为 BridgeGuardian-V3，每 60s 运行一次
  ├── BootTrigger (P365D): 系统重启后自动触发
  ├── CalendarTrigger: 当天重复 P1D
  └── 检查 .watcher_heartbeat、worker pool 存活

Layer 2: Watcher 自升级
  ├── 主循环每 ~50 次迭代检查 watcher.ps1 文件 LastWriteTime
  ├── 检测到变更 → 启动 restarter → 排空 inflight → 退出
  ├── restarter 检测退出 → 启动新 watcher
  └── 停机时间 < 2s

Layer 3: Worker 自修复
  ├── 实时: Get-WorkerForType 跳过死 worker
  └── 周期: Guardian 检查 worker pool，死 > 阈值时 respawn
```

### 5.2 自升级路径

```
文件变更检测 ──→ Test-SelfUpgrade ──→ 启动 restarter ──→ 新进程生效
     │                                    │
     │                          OldPID=当前watcher PID
     │                          等待退出后启动新 watcher
     │
副路径: __BRIDGE_RESTART__ metacommand → 同上
```

**V22 回归修复（本对话）**：`Test-SelfUpgrade` 原来只在内 `-not $pipeDispatched` fallback 路径执行，80%+ 的 Named Pipe 路径从不触发。已移到主循环 step 4a，每个命令周期都检查。

### 5.3 bridge_agent 健康检查

向 Invoke-Housekeeping（每 ~5min 运行）新增：
- bridge_agent TCP :19850 可用性检测（Get-NetTCPConnection）
- Proxy localhost:4000 健康检查
- 两者均有自动重启逻辑（mirror guardian_v3.ps1 Steps 5-6）

---

## 6. 命令分发流程（完整路径）

### 6.1 TCP 主路径（80%+ 命令）

```
1. Claude → bridge_client.py TCP :19850
2. bridge_agent 解析命令 JSON
3. load_worker_pool() 获取可用 worker（30s TTL 缓存）
4. is_pid_alive() 过滤死 worker
5. find_all_workers() 获取同类型全部候选
6. round-robin CallNamedPipe (timeout=0, 3 retry)
7. 收到 ACK → 轮询 r_{cmd_id}.json (100ms)
8. 收到结果 → TCP 响应返回
```

### 6.2 File Fallback 路径（~20%）

```
1. queue_serial 锁获取
2. 写 queue.txt + WriteAllText
3. bridge_wait.py 100ms 轮询 r_{cmd_id}.json
4. 收到结果 → 释放锁
5. watcher 内部: queue → pending → Named Pipe → worker → 结果
```

### 6.3 Watcher 内部循环（920 行主循环）

V22 重构为 9 个 handler 函数：

```
1. Invoke-Housekeeping       ← 健康检查、清理
2. Invoke-PollInflight       ← 检查飞行中命令完成
3. Invoke-HandleDedup        ← content-hash 去重 (2min 窗口)
4. Test-SelfUpgrade          ← 自升级检测
5. Invoke-ApplyRules         ← 规则引擎变换命令
6. Invoke-MetaCommand        ← 元命令处理
7. Invoke-InlineExecution    ← 进程内执行
8. Invoke-UserContextExecution ← 用户上下文执行
9. Invoke-InprocessFallback  ← 回退执行
```

---

## 7. 代理桥参考

> 代理桥不需要重构。本文档仅作为双桥架构的完整性引用。

| 项目 | 内容 |
|------|------|
| 代码 | `D:\zebbingo\tools\claude-desktop-config\proxy\server.py` (~1970 行) |
| 配置 | `config.yaml`: 双 provider (xiaomi/zhipu), 格式 anthropic/openai |
| 端口 | 4000 (localhost), 通过 tap0 网关 172.16.10.254:7897 出网 |
| 性能 | 处理开销 <50ms, 后端延迟 1.9-6.4s, SSE 流式连续无断裂 |
| 关键修复 | 移除 GZip, sort_keys 浅层化, SSE 零拷贝, 429 熔断, thinking 透传 |
| 状态 | **稳定运行，无需重构** |

---

## 8. 关键决策记录

### 8.1 为什么 TCP 而不是修复 9P

**决策**：彻底绕过 9P（TCP 桥），而非继续优化 9P 写缓存。

| 方案 | 延迟 | 复杂度 | 可靠性 | 结论 |
|------|------|--------|--------|------|
| os.fsync() 强制刷写 | ~10s | 低 | 中（非保证） | ❌ 临时 hack |
| 内核参数调优 | — | 高 | 未知 | ❌ 不可控 |
| TCP 桥 | 0.8ms | 中 | 高 | ✅ 最终方案 |

**教训**：当基础设施（9P FUSE）有不可控的行为限制时，从架构层面绕过比渗透式修复更有效。

### 8.2 为什么 PowerShell 5 而非 PowerShell 7

**决策**：保持 PS5。

- PS7 是可选安装，不保证存在
- PS5 是 Windows 内置，S4U 环境下更稳定
- PS5 的 `using module` 在 isolated runspace 中失败过（用 dot-sourcing `Import-Module` 替代）

### 8.3 为什么 "禁止 bash" 规则已废弃

旧规则诞生于 VM 不稳定期（沙箱无网络、bwrap crash），当时只能通过 queue.txt 通信。现在：
- VM 有 tap0 网络，TCP 0.8ms
- bridge_client.py 是标准工具
- bash 只是运行 bridge_client.py 的载体

**更新**：bash + TCP 桥是推荐路径；queue.txt 是回退路径。

### 8.4 为什么 EventWaitHandle 被移除

PowerShell 5.1 非交互 session（S4U / Scheduled Task）中，EventWaitHandle 内核对象导致 CLR 崩溃 → watcher 每 6 秒重启。改为纯轮询模式。

### 8.5 为什么写文件用 Write-SafeFile（temp+rename）

```
写入临时文件 → Move-Item（NTFS 同卷 rename 原子操作）
```
确保读取方要么看到旧文件（完整），要么看到新文件（完整）。无中间"部分写入"状态。

---

## 9. 运行状态与验证

### 9.1 组件状态（2026-06-06 22:39）

| 组件 | 状态 | 关键指标 |
|------|------|---------|
| bridge_agent.py (:19850) | ✅ 运行 | PID 19476, pipe_mode=win32pipe, watchdog active |
| watcher.ps1 | ✅ 运行 | PID 19756, 心跳新鲜, V22 |
| Worker pool | ✅ 14/14 存活 | 6 generic + 4 file + 2 process + 2 system + 1 wsl + 1 user |
| Guardian v3 | 🔴 已禁用 | 与 restarter 冲突，bridge_agent watchdog 已取代 |
| Proxy server.py | ✅ 运行 | localhost:4000, V13 |
| TCP bridge Phase 3 | ✅ 已部署 | Named Pipe 直接分发，17ms 往返 |

### 9.2 验证清单

| 验证项 | 方法 | 状态 |
|--------|------|------|
| Named Pipe 派发 | `pipe_direct:true` 标志 | ✅ |
| content-hash 去重 | `CONTENT DEDUP HIT` 日志 | ✅ |
| 自升级 | 修改 watcher.ps1 → restarter → 新进程 | ✅ 已验证 |
| 9P 读缓存穿透 | r_cmd.json <25ms | ✅ |
| 并发执行 | 3×8s sleep < 24s wall time | ✅ |
| Worker 故障跳过 | kill 一个 worker → 自动分配到其他 | ✅ |
| V22 handler 分离 | 9 个 handler 正常运行 | ✅ |

---

## 10. 未来方向

### 10.1 短期可做的

| 待办 | 原因 | 优先级 |
|------|------|--------|
| 重新启用 Guardian（修正后） | bridge_agent watchdog 是 Python 进程，如果 bridge_agent 本身崩溃则无保护 | 高 |
| 旧约定记忆文件清理 | bash-disabled, bridge-only-workflow 等旧记忆仍可能被加载 | 已完成 |
| 统一 `exit_code` 字段 | 部分地方用 `e` 或 `exitcode`，不一致 | 低 |
| 标准化规则引擎热加载 | 当前规则文件修改需等待 housekeeping 周期 | 低 |

### 10.2 架构层面的思考

1. **无单点风险**：当前 bridge_agent.py 是单点。如果它崩溃又没有 Guardian，watcher 失联。Guardian 重启 bridge_agent 是合理的下一步。

2. **日志中心化**：当前日志分散在 watcher.log、fallback.log、worker.log、agent.log。如果未来需要集中日志/告警，需要日志聚合层。

3. **安全边界**：TCP :19850 当前绑定 0.0.0.0，只靠 IP 范围（172.16.10.0/24）控制。如果宿主机有其他用户，这是个风险。

4. **Phase 4（可选）**：bridge_agent 完全替代 watcher，直接管理 worker pool。当前不需要（watcher 的运行开销很低），但为未来架构简化保留了路径。

### 10.3 已知未解决的问题

- **审计日志双写**：uvicorn 双加载模块导致双 handler，修复已准备好（`if not _audit_logger.handlers:`），需重启 proxy 生效
- **Worker progress 文件**：Named Pipe 派发的长命令每 5s 写 progress.json，但 TCP 通道的结果不包含进度信息
- **定时任务/计划任务**：当前没有调度框架，如需定时执行命令需要新增

---

## 附录 A：核心文件索引

| 文件 | 内容 | 生成时间 |
|------|------|---------|
| `docs/ARCHITECTURE.md` | **本文档** — 架构白皮书（唯一权威参考） | 2026-06-06 |
| `docs/EVOLUTION.md` | 完整演变史（V1→V22, 每版本细节） | 2026-06-04 |
| `docs/9p-cache-handbook.md` | 9P 缓存完整研究（V2.0） | 2026-06-06 |
| `docs/TCP-MIGRATION-PLAN.md` | TCP 迁移方案（Phase 1-3 已完成） | 2026-06-06 |
| `docs/dual-bridge-architecture.md` | 双桥架构总览（V1.4） | 2026-06-06 |
| `docs/HANDOFF-2026-06-06.md` | Phase 3 交接文档 | 2026-06-06 |
| `docs/powershell-best-practices.md` | PowerShell 5 最佳实践 | 2026-06-06 |

## 附录 B：内存文件索引（跨会话）

```
bridge-workflow-current.md    — 当前工作流: bash + TCP 桥
9p-cache-handbook.md          — 9P 缓存研究指针
feedback-bridge-polling.md    — 结果等待: 100ms 轮询
tcp-bridge-phase3.md          — Phase 3 部署记录
self-healing-architecture.md  — 四层自愈体系
v22-refactoring-complete.md   — V22 重构与部署
```

## 附录 C：术语表

| 术语 | 含义 |
|------|------|
| 9P / virtiofs | Plan 9 文件系统协议，VM 挂载宿主目录 |
| FUSE | Filesystem in Userspace，用户态文件系统 |
| write-back cache | 写入缓存在客户端，异步发送到服务器 |
| watcher | PowerShell 进程，主循环调度命令 |
| Named Pipe | Windows 进程间通信通道 (`\\.\pipe\Cluster_Wkr_*`) |
| guardian | 看守器进程，检测故障并自动恢复 |
| restarter | 自包含的 watcher 重启器 |
| Phase 3 | TCP → Named Pipe 直接分发，跳过文件系统 |
