# 通信桥 TCP 迁移方案

> 版本：V1.0 | 日期：2026-06-06 | 基于 Cowork VM 架构升级后的实测数据

---

## 1. 背景与动机

### 1.1 Cowork 沙箱架构已升级

Cowork 桌面端已完成沙箱架构升级（约 2026-06-06）：

| 项目 | 旧架构 | 新架构 |
|------|--------|--------|
| 网络隔离 | `--unshare-net`（完全隔离） | 已移除，沙箱有 tap0 网卡 |
| 网卡 | 无 | tap0: 172.16.10.3/24 |
| 代理方式 | socat → unix socket | 直接走网关 172.16.10.254:7897 |
| 设备访问 | `--dev /dev`（最小集） | `--dev-bind / /`（完整 rootfs） |
| RPC 通道 | （无/vsock 被阻断） | virtio-serial `claude-daemon-console` |
| bwrap | `--ro-bind / / --dev /dev --unshare-net` | `--dev-bind / / --unshare-pid` |

**关键数据：跨 VM TCP 延迟 0.8ms，virtiofs 文件操作 12.7ms（fsync）。**

### 1.2 当前瓶颈

通信桥的第一跳（沙箱 → watcher）仍然通过 queue.txt 文件轮询：

```
Claude 沙箱 --写 queue.txt (virtiofs, 12.7ms fsync)--
  → FSW 检测 (50ms 延迟)--
    → watcher 分发 (Named Pipe, 18ms)--
      → worker 执行--
        → 写 r_{cid}.json (virtiofs)--
          → Claude 轮询结果 (6-22ms + 轮询间隔)
```

实测总延迟：~160ms（echo roundtrip）。

如果改用 TCP：
```
Claude 沙箱 --TCP 请求 (0.8ms)--
  → bridge_agent 分发 (Named Pipe, 18ms)--
    → worker 执行--
      → 结果通过 TCP 响应返回 (0.8ms)
```

预期延迟：~20ms（主要在 Named Pipe IPC 和 worker 执行）。

### 1.3 收益量化

| 指标 | queue.txt 方案 | TCP 方案 | 改善 |
|------|---------------|----------|------|
| 入口延迟 | 12.7ms (fsync) + 50ms (FSW) | 0.8ms (TCP RTT) | **~70x** |
| 结果获取 | 6-22ms (轮询) + 50-100ms (poll interval) | 0ms (TCP 响应直接返回) | **∞** |
| 并发安全 | 无文件锁，竞争覆盖 | TCP 协议天然串行化 | **消除竞争** |
| 总 roundtrip | ~160ms (echo) | ~20ms (预估) | **~8x** |

---

## 2. 目标架构

```
┌──────────────────────────────────────────────────────────────┐
│                    Linux VM (Cowork Sandbox)                  │
│                                                              │
│  Claude Agent                                                │
│    │                                                         │
│    │ TCP (0.8ms 跨 VM)                                       │
│    │                                                         │
│    ▼                                                         │
│  bridge_client.py (沙箱端轻量客户端)                           │
│    - 建立到 Windows 的 TCP 长连接                              │
│    - 发送命令 JSON，接收结果 JSON                               │
│    - 连接断开时自动重连                                        │
│    - fallback: 如果 TCP 不可用，回退 queue.txt                 │
│                                                              │
└──────────┬───────────────────────────────────────────────────┘
           │ TCP (172.16.10.3 → 172.16.10.1:PORT 或
           │        172.16.10.254:PORT)
┌──────────▼───────────────────────────────────────────────────┐
│                    Windows Host                               │
│                                                              │
│  bridge_agent.py (新组件，轻量 TCP 服务端)                      │
│    - 监听 TCP 端口                                            │
│    - 接收命令 JSON                                            │
│    - 转发到 watcher 内部 Named Pipe 分发                       │
│    - 收集结果，通过 TCP 响应返回                                │
│    - 与现有 worker pool 完全复用                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  现有 watcher + worker pool (不变)                     │    │
│  │  watcher.ps1 V2.2                                     │    │
│  │  worker_factory + 14 workers (Named Pipe)             │    │
│  │  Guardian v3 自愈体系                                   │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 3. 分阶段实施计划

### Phase 1：TCP Agent（Windows 端）— 最小可用

**目标：** 在 Windows 端新增一个 TCP 服务，接收命令并转发到 watcher。

**新增文件：** `claude-bridge/bridge_agent.py`

**职责：**
1. 监听 TCP 端口（默认 19850，仅限 172.16.10.0/24 网段）
2. 接收命令 JSON（与 queue.txt 格式完全一致）
3. 将命令写入 watcher 的 queue.txt（**复用现有入口**，最简单）
4. 轮询 `r_{cmd_id}.json` 等待结果
5. 通过 TCP 响应返回完整结果
6. 连接关闭时清理

**为什么先写 queue.txt 而不是直接 Named Pipe：**
- 最小改动原则 — watcher 代码完全不变
- queue.txt 写入对 watcher 来说是原子操作
- 一次验证一个变量（先验证 TCP 通道，再优化内部路径）

**预估工作量：** ~200 行 Python

**预估延迟改善：**
- 入口：12.7ms (fsync) + 50ms (FSW) → 0.8ms (TCP) + 12.7ms (fsync) + 50ms (FSW) = **TCP 端节约的是结果轮询**
- 实际上 Phase 1 的主要收益是：Claude 不再需要自己写文件和轮询文件，bridge_agent 帮它做了
- 但总延迟改善有限，因为 queue.txt → FSW 这一段没变

### Phase 2：沙箱端客户端

**目标：** 在沙箱内提供 bridge_client，Claude 通过它发命令。

**新增文件：** `claude-bridge/bridge_client.py`（部署到沙箱可访问路径）

**职责：**
1. 连接到 bridge_agent TCP 端口
2. 发送命令，等待响应
3. 支持超时、重连
4. CLI 接口：`python3 bridge_client.py '{"command":"echo hi","type":"powershell","timeout":30}'`
5. Fallback：如果 TCP 连接失败，回退到 queue.txt 写入 + poll_result.sh 轮询

**预估工作量：** ~150 行 Python

### Phase 3：直接 Named Pipe 分发（跳过 queue.txt）

**目标：** bridge_agent 不再写 queue.txt，直接通过 Named Pipe 分发到 worker。

**改动文件：** `claude-bridge/bridge_agent.py`（修改 Phase 1）

**变更：**
1. bridge_agent 读取 `.worker_pool.json` 获取可用 worker
2. 直接通过 Named Pipe 连接 `Cluster_Wkr_{type}_{n}`
3. 发送命令，等待 ACK
4. 轮询 `r_{cmd_id}.json` 获取结果
5. 通过 TCP 响应返回

**这一步消除了：**
- queue.txt 文件写入（-12.7ms）
- FileSystemWatcher 延迟（-50ms）
- 文件竞争风险（完全消除）

**预估延迟改善：** ~160ms → ~25ms

### Phase 4：bridge_agent 成为 Watcher 替代

**目标：** bridge_agent 成为新的主入口，watcher 保留为 Fallback。

**改动：**
1. bridge_agent 直接管理 worker pool
2. bridge_agent 注册为 Windows Service 或 Scheduled Task
3. watcher 作为独立通道保留（用于直接文件操作场景）

**这一步是可选的** — 如果 Phase 3 效果已经足够好，可以不做 Phase 4。

---

## 4. 协议设计

### 4.1 TCP 协议（Phase 1-3）

基于 JSON + 换行符分隔的简单协议：

**请求（沙箱 → Windows）：**
```json
{"cmd_id":"test_001","command":"echo hello","type":"powershell","timeout":30}\n
```

**响应（Windows → 沙箱）：**
```json
{"state":"done","cmd_id":"test_001","exit_code":0,"stdout":"hello\r\n","stderr":"","duration_ms":123,"timestamp":"2026-06-06 10:00:00"}\n
```

**错误响应：**
```json
{"state":"error","cmd_id":"test_001","exit_code":-1,"stdout":"","stderr":"connection refused","error":"worker unavailable","duration_ms":0}\n
```

**心跳（可选）：**
```json
{"type":"ping"}\n
→ {"type":"pong","workers":14,"inflight":0}\n
```

### 4.2 端口与安全

| 参数 | 值 | 说明 |
|------|-----|------|
| 端口 | 19850 | 固定端口，不与现有服务冲突 |
| 绑定 | 0.0.0.0:19850 | 允许来自 172.16.10.0/24 的连接 |
| 认证 | 无（Phase 1） | 仅限内网网段，无外部暴露 |
| TLS | 不需要 | 内网通信 |
| 并发 | 最多 5 连接 | Claude 通常串行发命令 |

### 4.3 Fallback 策略

```python
def send_command(cmd):
    # 1. 尝试 TCP
    try:
        return tcp_send(cmd, timeout=cmd.get('timeout', 30) + 5)
    except (ConnectionRefused, TimeoutError):
        pass
    
    # 2. Fallback 到 queue.txt
    return file_bridge_send(cmd)
```

---

## 5. 实施约束

### 5.1 不改动的部分

| 组件 | 原因 |
|------|------|
| watcher.ps1 | 完全不变，Phase 1-2 复用现有入口 |
| worker pool | 完全复用，Named Pipe 协议不变 |
| Guardian v3 | 继续监控 watcher，bridge_agent 是独立进程 |
| 代理桥 (server.py) | 已经是 HTTP 协议，不需要迁移 |
| bridge_rules.json | 规则引擎继续生效（如果走 queue.txt 路径） |

### 5.2 可选优化（不阻塞主流程）

- queue.txt 加文件锁（flock / Mutex）— 降低并发风险
- bridge_agent 用 Python asyncio 而非线程 — 更轻量
- bridge_agent 注册为 Windows Service — 比 Scheduled Task 更可靠
- 双向 WebSocket — 替代 TCP + JSON，支持推送通知

### 5.3 回滚方案

每个 Phase 都是增量添加，回滚只需要：
1. 停止 bridge_agent.py
2. Claude 继续使用 queue.txt
3. 不影响任何现有功能

---

## 6. 验证标准

### Phase 1 验证

- [ ] bridge_agent 启动，TCP 端口可连接
- [ ] 发送命令 → 写入 queue.txt → watcher 处理 → 结果返回
- [ ] 延迟对比：TCP 通道 vs 直接 queue.txt
- [ ] 错误场景：watcher 未启动、worker 全忙、超时

### Phase 2 验证

- [ ] bridge_client 在沙箱内可用
- [ ] TCP 连接成功，命令发送和结果接收正常
- [ ] Fallback 到 queue.txt 在 TCP 不可用时自动触发
- [ ] echo roundtrip < 50ms（vs 旧 160ms）

### Phase 3 验证

- [ ] bridge_agent 直接 Named Pipe 分发
- [ ] echo roundtrip < 30ms
- [ ] 并发 10 命令全部成功
- [ ] worker 故障时自动跳过，不影响其他命令

---

## 7. 时间线估计

| Phase | 工作量 | 依赖 | 风险 |
|-------|--------|------|------|
| Phase 1 | 1-2 小时 | 无 | 低 — 只是加一层代理 |
| Phase 2 | 1 小时 | Phase 1 | 低 — 简单客户端 |
| Phase 3 | 2-3 小时 | Phase 1-2 | 中 — 需要复用 Named Pipe 协议 |
| Phase 4 | 3-5 小时 | Phase 3 | 高 — 架构变更较大 |

**建议：先做 Phase 1+2，验证效果，再决定是否做 Phase 3。**

---

## 8. 与代理桥的关系

代理桥 (server.py, localhost:4000) **不需要任何改动**：
- 它已经是 HTTP 协议，走的是网络通道
- 新架构中它通过 tap 网卡的网关代理访问
- 性能特征不变（<50ms 代理开销）
- 与通信桥独立运行

两个桥的定位不变：
- **代理桥**：AI 模型 API 转发（Anthropic ↔ OpenAI）
- **通信桥**：宿主机命令执行（PowerShell/文件/进程）
- TCP 迁移只影响通信桥的入口通道
