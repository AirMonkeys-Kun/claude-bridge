# 9P/virtiofs 缓存问题研究与解决方案

> 最后更新：2026-06-06 | 版本：V2.0

---

## 目录

1. [问题背景](#1-问题背景)
2. [缓存机制分析](#2-缓存机制分析)
3. [V18 唯一文件名方案（读缓存修复）](#3-v18-唯一文件名方案读缓存修复)
4. [Write-SafeFile temp+rename 原子写（写撕裂修复）](#4-write-safefile-temprename-原子写写撕裂修复)
5. [写端缓存：queue.txt 的根本难题](#5-写端缓存queue-txt-的根本难题)
6. [终极方案：TCP 桥（绕过 9P 文件系统）](#6-终极方案tcp-桥绕过-9p-文件系统)
7. [旧约定为何需要更新](#7-旧约定为何需要更新)
8. [快速决策树](#8-快速决策树)
9. [变更记录](#9-变更记录)

---

## 1. 问题背景

Claude 运行在 Cowork 的 Linux VM 沙箱中。沙箱通过 **virtiofs (Plan 9 协议)** 将宿主目录映射到 VM 内部。VM 对映射目录的所有文件操作都经过 9P FUSE 客户端 → virtiofs → Windows 宿主。

```
Linux VM (Claude)                     Windows Host
   │                                      │
   │  Write queue.txt (via 9P)            │
   │ ──────────────────────────►           │ 9P 客户端缓存写入
   │                                      │  ??? 延迟后 ??? 才到达
   │                                      │
   │  Read r_cid.json (via 9P)            │
   │ ──────────────────────────►           │ 9P 客户端缓存读取
   │ ◄────────── 可能返回旧数据            │
```

9P FUSE 默认启用 **write-back caching** — 写入完成在客户端确认（`write()` 立即返回），但数据传输到服务器是异步的。读取也有缓存：相同文件名的重复读取可能返回缓存中的旧数据。

### 受影响的场景

| 场景 | 影响 |
|------|------|
| VM 写 queue.txt → 期待 watcher 处理 | 写延迟 5-30s+（最严重） |
| VM 读 r_{cid}.json 结果 | 读延迟 200-600ms（V18 已修复） |
| VM 读 .watcher_heartbeat | 看到旧时间戳，误判 watcher 死亡 |
| VM 写 .watcher_heartbeat | watcher 正常写入，不受影响（写入方是 Windows 进程） |

---

## 2. 缓存机制分析

### 2.1 写缓存（Write-back Cache）

9P FUSE 客户端对固定文件名的写入默认启用 write-back caching：

```
VM 进程: write(queue.txt) → 9P 客户端确认返回
                                │
                            ??? ms later (不可预测)
                                │
Windows:                  ← 实际数据到达
```

缓存刷新条件：
- 客户端内存压力（kernel 回收脏页）
- 手动 `fsync()` / `sync()`
- 文件关闭后超时（内核 writeback 定时器，通常 5-30s）

**关键发现**：`close()` 不会立即触发 9P flush。即使文件被关闭，数据仍可能留在客户端缓存中。只有 `fsync()` 强制刷到服务器。

### 2.2 读缓存（Read Cache）

9P FUSE 对重复文件名的读取启用缓存：

```
VM 进程: read(queue.txt) → 9P 客户端: cache hit → 返回旧数据
                          （200-600ms 后才看到新数据）

VM 进程: read(r_uniq_cid.json) → 9P 客户端: cache miss → 读取最新
                          （<25ms 直接穿透到服务器）
```

**修复（V18）**：对结果文件使用唯一文件名（`r_{cmd_id}.json`），使每次读取都是 cache miss，强制穿透到服务器。

### 2.3 关键区别：文件名固定性

| 文件 | 文件名模式 | 读缓存问题 | 写缓存问题 |
|------|-----------|-----------|-----------|
| `queue.txt` | 固定 | 无（FSW + 轮询） | **有** — VM 写有延迟 |
| `r_{cmd_id}.json` | 每次唯一 | 无（V18 修复） | **有** — 但写入方是 Windows 进程 |
| `.watcher_heartbeat` | 固定 | 无（Windows 进程写入） | 无（Windows 进程写入） |
| `.watcher.lock` | 固定 | 无 | 无（仅首次创建） |

**核心规律**：Windows 进程写入的文件 → 无缓存问题。VM 进程写入的文件 → 有缓存问题（读或写）。

---

## 3. V18 唯一文件名方案（读缓存修复）

### 发现日期

2026-06-04

### 问题现象

从 VM 侧读取 `.pipe_batch_result.json` 结果文件时，90% 请求命中 9P 读缓存：
- 200-600ms 后才看到最新数据
- 表现为「结果文件存在但内容为空或旧数据」

### 根因

`cat .pipe_batch_result.json`（复用文件名）→ 9P FUSE 命中缓存 → 返回旧数据

### 解决方案

结果文件使用**唯一文件名**，每命令一个：

```
# 慢（固定文件名 — 读缓存命中）：
cat watcher/.pipe_batch_result.json    # 200-600ms

# 快（唯一文件名 — 穿透缓存）：
cat watcher/r_my_unique_id.json        # <25ms
```

### 验证

所有 `r_{cid}.json` 文件从 VM 侧即时读取，无 9P 缓存延迟。

### 适用范围

| 适用 | 不适用 |
|------|--------|
| ✅ 结果文件读取（`r_{cid}.json`） | ❌ 队列文件写入（`queue.txt`） |
| ✅ 任意唯一文件名的读取 | ❌ 固定文件名的读取 |
| | ❌ 固定文件名的写入 |

---

## 4. Write-SafeFile temp+rename 原子写（写撕裂修复）

### 发现日期

2026-06-05

### 问题现象

`bridge_wait.py`（或 VM 侧的轮询）在读取 `r_{cmd_id}.json` 时，发现文件存在但内容不完整（partial write）。这是因为 9P 的文件元数据（存在性、大小）先于内容到达：

1. `WriteAllText()` 创建文件 — 9P 传递「文件存在」
2. VM 侧轮询检测到文件存在 → 立即读取 → 内容不全
3. 内容实际到达 → 正确

### 解决方案

所有文件写入使用 **temp + rename** 原子写模式：

```powershell
# 写入到临时文件
[System.IO.File]::WriteAllText("$Path.tmp", $content, $utf8)
# 原子重命名（NTFS 同卷 rename 是原子的）
Move-Item -LiteralPath "$Path.tmp" -Destination $Path -Force
```

在 NTFS 上，同卷 `Move-Item` 是**元数据操作**（1-2ms），不拷贝文件内容。读取方要么看到旧文件（完整），要么看到新文件（完整）。没有中间「部分写入」状态。

### 实现位置

`modules\BridgeCommon.psm1` 中的 `Write-SafeFile` 函数和 `Write-Heartbeat` 函数。

### 适用范围

| 适用 | 不适用 |
|------|--------|
| ✅ 从 Windows 侧写入文件时 | ❌ 从 VM 侧写入文件（9P 写缓存存在） |
| ✅ 防止 partial read 撕裂 | ❌ 消除 9P write-back 延迟 |

---

## 5. 写端缓存：queue.txt 的根本难题

### 问题描述

`queue.txt` 是通信桥的核心入口，但它的文件名必须**固定**（watcher 和 bridge_agent 都用这个路径读取）。VM 侧写入 `queue.txt` 经过 9P write-back 缓存，导致：

- 写入后 5-30s Windows 侧才看到更新
- FSW（FileSystemWatcher）不会触发 Change 事件
- watcher 的 50ms 轮询读取到旧内容

### 为什么 Write-SafeFile 不能解决

Write-SafeFile 的 temp+rename 模式解决了**读撕裂**（partial read），但绕不过 9P 的 write-back 缓存。即使用临时文件名写入再 rename，rename 本身也是一个 9P 操作，同样会被缓存：

```
VM: write(queue.txt.tmp) → 9P 缓存
VM: rename → 9P 缓存（不立即发送）
                       ... 5-30s ...
Windows: 收到 rename → 看到新文件
```

### 尝试过的缓解措施

| 措施 | 效果 | 结论 |
|------|------|------|
| 从 bash `sync` | 仅刷新 Linux 内核缓冲区 | 不够（不强制 9P flush） |
| Python `os.fsync()` | 强制 9P flush | 部分有效（延迟从 30s 降到 10s） |
| 内核 `fsync` 命令 | bash 没有内置 fsync | 需通过 Python/C 实现 |

### 唯一稳定的变通

通过 Python 的 `os.fsync(fd)` 对 9P 挂载的文件描述符进行强制刷写：

```python
with open(queue_path, 'w') as f:
    f.write(json.dumps(cmd))
    f.flush()
    os.fsync(f.fileno())  # 强制 9P flush 到服务器
```

但这仍然是 hack，不是根因修复。

---

## 6. 终极方案：TCP 桥（绕过 9P 文件系统）

### 架构演进

```
Phase 0（旧）:  ❌  queue.txt（纯文件，9P 写缓存）
Phase 1（过渡）: ⚠️  TCP → queue.txt → watcher（减少 VM 侧写）
Phase 2（中间）: ✅  TCP 优先 → queue.txt fallback（常见场景）
Phase 3（当前）: ✅🔑 TCP → Named Pipe（完全绕过 queue.txt 文件）
```

### Phase 3 架构

```
Claude VM                           Windows Host
   │                                      │
   │ TCP :19850 (0.8ms RTT)               │
   │ ──────────────────────────►           │
   │                                      │
   │                          bridge_agent.py
   │                            │
   │                            ├─ Named Pipe → worker（80% 路径）
   │                            │    Cluster_Wkr_generic_1
   │                            │    Cluster_Wkr_file_2
   │                            │    ... 
   │                            │
   │                            └─ queue.txt → watcher（fallback）
   │                                     │
   │ ◄──────────── TCP 响应 (结果 JSON)   │
```

**关键**：bridge_agent.py 是 Windows 进程，它写入 `queue.txt` 时不受 9P 缓存影响（直接写 Windows NTFS）。VM 侧不需要接触 `queue.txt`。

### 使用方式

从 VM 侧使用 `bridge_client.py`（已在项目根目录中）：

```bash
# TCP 模式（推荐）
python3 bridge_client.py '{"command":"echo hello","type":"powershell","timeout":30}'

# Ping 健康检查
python3 bridge_client.py --ping

# 强制文件回退（调试用）
python3 bridge_client.py --fallback '{"command":"echo hi"}'

# 结构化参数
python3 bridge_client.py --cmd "dir" --type cmd --timeout 10
```

### 验证数据

| 方案 | avg | p50 | p99 | 9P 缓存问题 |
|------|-----|-----|-----|------------|
| Phase 3 TCP (pipe direct) | **17ms** | 16ms | 41ms | ✅ 无 |
| Phase 1 TCP (queue.txt) | 109ms | 103ms | 156ms | ✅ 无（bridge_agent 是 Windows 进程）|
| File only (queue.txt) | 195ms | 204ms | 211ms | ❌ 有 |
| 旧架构 | 160-244ms | — | — | ❌ 严重 |

### 比 9P 更好的原因

| 维度 | 9P 文件 | TCP |
|------|---------|-----|
| 延迟 | 12.7ms (fsync) | 0.8ms (RTT) |
| 缓存 | write-back (5-30s) | 无缓存 |
| 原子性 | 需 temp+rename 模拟 | 天然消息边界 |
| 竞争 | 无文件锁 | 天然串行化 |
| 扩展性 | 单文件 | 多连接并发 |

---

## 7. 旧约定为何需要更新

### 旧约定（已过时）

```
bash-disabled: 约定不使用 bash/沙箱，全部走通信桥 (watcher queue)
bridge-only-workflow: 禁止使用 mcp__workspace__bash，一切通过 queue.txt
```

### 更新原因

1. **queue.txt 受 9P write-back 缓存影响**，从 VM 写入有 5-30s 延迟
2. **通信桥已经演进到 Phase 3**，TCP 通道（bridge_agent :19850）是主入口
3. **bash 不是问题** — 问题在于用 queue.txt 文件传输，bash + TCP 是更好的途径
4. **bridge_client.py** 已是标准工具，通过 TCP 发送命令再通过 TCP 接收结果

### 新约定

```
通信桥的虚拟机侧入口：
  ✅ TCP（推荐）：bridge_client.py → bridge_agent:19850（0.8ms，无缓存）
  ⚠️ 文件（回退）：write queue.txt + poll r_{cid}.json（有 9P 缓存延迟）

避免：
  ❌ 通过 9P 直接写 queue.txt 作为主要方式（write-back 缓存 5-30s）
  ❌ 在 mac 或 linux 的 powershell 脚本中依赖 fsync（不是所有环境都支持）
```

---

## 8. 快速决策树

```
需要向 watcher/worker 提交命令
   │
   ├─ 从 VM 侧 (Claude 沙箱)
   │    │
   │    ├─ ✓ TCP 可用 → bridge_client.py（推荐，0.8ms，无缓存）
   │    │
   │    └─ TCP 不可用 → queue.txt + 使用 Python os.fsync()
   │                     （避免 9P write-back 缓存）
   │
   ├─ 从 Windows 侧（PowerShell 脚本）
   │    │
   │    ├─ 写 queue.txt → 直接 Write-SafeFile（Windows 侧不受 9P 影响）
   │    └─ 写结果文件 → Write-CommandResult（自动 temp+rename）
   │
   └─ 从 VM 侧读取结果
        │
        └─ r_{cmd_id}.json → 唯一文件名，自然绕过 9P 读缓存
                             （V18 已验证 <25ms）
```

---

## 9. 变更记录

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-06-06 | V1.0 | 初始版本 — V18 唯一文件名方案总结 |
| 2026-06-06 | V2.0 | 新增写缓存分析、Write-SafeFile 原子写、TCP 终极方案、决策树、旧约定更新 |

---

**相关文档**：
- `EVOLUTION.md` — V18 节（唯一文件名方案）和 V22 节（Phase 3 TCP 迁移）
- `TCP-MIGRATION-PLAN.md` — TCP 迁移完整方案和验证数据
- `dual-bridge-architecture.md` — 双桥架构总览（Phase 3 已完成）
- `modules/BridgeCommon.psm1` — Write-SafeFile 和 Write-Heartbeat 的 temp+rename 实现
- `bridge_client.py` — VM 侧 TCP 客户端（标准用法）
- `bridge_agent.py` — Windows 侧 TCP 服务端
- `powershell-best-practices.md` — 第 3 节（文件 I/O 编码）和第 4 节（模块编写）
