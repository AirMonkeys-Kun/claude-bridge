# 双桥架构 — 代理桥 + 通信桥

> 最后更新：2026-06-06 | 版本：V1.3

---

## 概述

Claude 在 Cowork 环境中通过两座"桥"突破了原本的能力边界：

1. **代理桥 (Proxy Bridge)** — via tap0 网关代理，让 Claude 能使用非原生 AI 后端（xiaomi mimo、zhipu GLM），同时保持完整的 Anthropic API 兼容性
2. **通信桥 (Communication Bridge)** — watcher + worker pool + TCP/文件双通道，让 Claude 能在 VM 沙箱内执行宿主机操作（PowerShell、文件、进程管理等）

两座桥各司其职，组合起来使 Claude 从一个"只能聊天的 AI"变成了一个"能操作宿主机的全栈助手"。

---

## Cowork 沙箱架构（2026-06-06 更新）

Cowork 桌面端已完成沙箱网络架构升级。沙箱从完全隔离（`--unshare-net`）升级为具备真实网络（tap0 网卡），通信桥的入口通道可从纯文件演变为 **TCP + 文件双通道**。

### 沙箱网络拓扑

```
Linux VM (Cowork Sandbox)
  bwrap: --dev-bind / / --proc /proc --unshare-pid --die-with-parent
  (不再有 --unshare-net，沙箱有完整网络能力)

  ├── tap0: 172.16.10.3/24     ← 真实网络，可直连宿主机
  ├── Gateway: 172.16.10.1     ← 默认网关 + DNS
  ├── SSH: port 22             ← 管理通道
  └── Proxy: 172.16.10.254:7897 ← HTTP/HTTPS 代理

  RPC 通道:
  ├── virtio-serial "claude-daemon-console" ← coworkd ↔ 宿主机 (bwrap 外)
  ├── virtiofs ← 文件共享 (outputs/uploads/memory/skills)
  └── tap0 TCP ← 沙箱可用 (0.8ms 跨 VM RTT)
```

### 跨 VM 通信延迟基准（2026-06-06 实测）

| 通道 | 平均延迟 | p99 | 说明 |
|------|---------|-----|------|
| virtiofs 文件 (fsync) | 12.7ms | 16.5ms | 旧桥写入方式 |
| virtiofs 文件 (无 fsync) | 1.9ms | 2.7ms | 数据可能不持久 |
| ICMP ping 网关 | 0.3ms | 0.7ms | 纯网络 RTT |
| TCP connect (跨 VM) | **0.8ms** | 0.9ms | **新可用通道** |
| TCP localhost echo | 0.038ms | 0.088ms | 沙箱内进程间 |
| Named Pipe (Windows 内) | 18.6ms | 29ms | watcher → worker |

### 架构演进对比

| 项目 | 旧架构 | 新架构 |
|------|--------|--------|
| 网络隔离 | `--unshare-net`（完全隔离） | **已移除**，tap0 网卡 |
| HTTP 代理 | socat → unix socket → 宿主机 | 直接走网关 172.16.10.254:7897 |
| 设备访问 | `--dev /dev`（最小集） | `--dev-bind / /`（完整 rootfs） |
| 代理环境变量 | bwrap setenv 20+ 行 | 外层注入 3 行 |
| 通信桥入口 | queue.txt (唯一选择) | **queue.txt + TCP (可选)** |
| vsock | 设备不可见，socket EPERM | 设备可见但仍 EPERM (seccomp) |

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Cowork Desktop                                    │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Claude Agent (Linux VM Sandbox, tap0: 172.16.10.3)         │   │
│  │  • 对话推理 ← 走代理桥 (HTTP via tap0 → 网关代理)             │   │
│  │  • 工具调用 (Read/Write/Bash) ← 本地 VM 内操作               │   │
│  │  • 宿主机操作 ← 走通信桥 (TCP 0.8ms / queue.txt Fallback)   │   │
│  └──────────┬──────────────────────────┬────────────────────────┘   │
│             │                          │                            │
│     ┌───────▼───────┐          ┌───────▼───────┐                    │
│     │   代理桥       │          │   通信桥       │                    │
│     │ via tap0      │          │ TCP + 文件    │                    │
│     │ V13 server.py │          │ watcher V2.2  │                    │
│     └───────┬───────┘          └───────┬───────┘                    │
│             │                          │                            │
└─────────────┼──────────────────────────┼────────────────────────────┘
              │ HTTP via tap0            │ TCP (0.8ms) + queue.txt
              ▼                          ▼
    ┌──────────────────┐      ┌─────────────────────┐
    │  xiaomi (mimo)    │      │  Worker Pool         │
    │  Anthropic 格式   │      │  process/file/system  │
    │  adaptive think   │      │  PowerShell 执行      │
    ├──────────────────┤      └─────────────────────┘
    │  zhipu (GLM)      │              │
    │  OpenAI 格式      │              ▼
    │  failover 兜底    │      ┌─────────────────────┐
    └──────────────────┘      │  宿主机操作结果       │
                              │  • 文件读写           │
                              │  • 进程管理           │
                              │  • 网络/端口           │
                              │  • 服务控制           │
                              └─────────────────────┘
```

---

## 代理桥 (Proxy Bridge)

**位置：** `D:\zebbingo\tools\claude-desktop-config\proxy\server.py` (V13)
**端口：** via tap0 网关代理
**协议：** HTTP (Anthropic Messages API passthrough)

### 核心能力

| 能力 | 说明 |
|------|------|
| 双格式 API | Anthropic 原生透传 (xiaomi) + OpenAI 转换 (zhipu) |
| 多 provider 容错 | 熔断器 + 自动 failover，xiaomi 不可用时切 zhipu |
| Adaptive thinking | 透传 Cowork 的 `adaptive` thinking，模型自决定思考深度 |
| SSE 流式直传 | 未修改事件零拷贝转发，无压缩无重序列化 |
| 模型路由 | sonnet/opus → xiaomi (premium)，haiku → zhipu (cheap) |
| 配置热更新 | config.yaml 修改后 5s 内自动生效，无需重启 |

### 性能特征 (2026-06-05 实测)

| 指标 | 数值 |
|------|------|
| 代理处理开销 | < 50ms |
| 后端延迟 (xiaomi) | 1.9 - 6.4s (中位数 ~3s) |
| Thinking tokens (tool_use) | 6-30 (简单), 175-368 (复杂) |
| Thinking tokens (end_turn) | ~312-368 |
| 流式传输 | 稳定连续，无断裂 |
| Audit 日志 | 每请求记录 provider/model/latency/status |

### 代理桥代码质量评估（2026-06-06）

server.py (1970 行) 功能完善，代码质量整体可控：

| 指标 | 状态 | 说明 |
|------|------|------|
| 全局可变状态 | 26+ 个 | asyncio 单线程下安全，但增加理解成本 |
| 最大函数 | 204 行 (`_generate_openai_stream`) | 流式转换逻辑，拆分收益有限 |
| 配置热重载 | 无锁 | `_reload_config()` 在 asyncio 内同步执行，安全 |
| 请求去重 | asyncio Future | 正确实现，无竞争 |
| 依赖 | FastAPI + httpx + PyYAML | 标准组合，无特殊风险 |
| 安全 | API keys 明文存储在 config.yaml | 内网环境可接受，不建议公网暴露 |

**结论：代理桥不需要重构。** 它已经是 HTTP 协议，走网络通道，性能和稳定性都符合预期。

---

## 通信桥 (Communication Bridge)

**位置：** `D:\zebbingo\tools\claude-bridge\`
**核心：** watcher.ps1 V2.2 + worker_factory.ps1 V2.2
**协议：** queue.txt 文件 IPC + Named Pipe 分发 (当前) / TCP (规划中)

### 核心能力

| 能力 | 说明 |
|------|------|
| 文件 IPC | Claude 写 queue.txt → watcher 轮询检测 → 分发执行 |
| Named Pipe 直连 | worker 结果通过 pipe 直接返回，绕过 9P 缓存延迟 |
| 异步分发 | V21 async dispatch，支持多命令并发 |
| Worker Pool | 按类型 (process/file/system/wsl/user) × 数量管理 |
| 自愈体系 | Guardian v3 监控 watcher，自动重启 + 自升级 |
| 规则引擎 | YAML 驱动的命令变换、学习、统计 |

### 性能特征 (2026-06-05 实测)

| 指标 | 数值 |
|------|------|
| Echo 命令 round-trip | 161-209ms |
| 脚本执行 (bridge_test.ps1) | 1443ms (8 项测试) |
| PowerShell 启动 | ~1ms |
| 文件读写 100 行 | 13ms |
| Dispatch 通道 | pipe_direct (直连) |
| Worker Pool | process×2, file×4, generic×4, system×2, wsl×1, user×1 |

### 通信桥代码质量评估（2026-06-06）

| 组件 | 行数 | 问题 | 严重性 |
|------|------|------|--------|
| watcher.ps1 | 920 | 主循环混合 10+ 职责，383 行 try/catch | 中 |
| watcher.ps1 | 920 | 5 处重复工具函数（文件读写、日志、心跳） | 低 |
| watcher.ps1 | 920 | V21 + legacy 双路径并存 | 中 |
| queue.txt | — | 无文件锁，并发竞争 | 高 |
| result JSON | — | 字段命名不一致 (`exit_code` vs `e`) | 低 |
| 全局变量 | ~20 | 脚本作用域可变状态，难追踪 | 低 |

### TCP 迁移路线（规划中）

沙箱现在有 tap0 真实网络（0.8ms RTT），queue.txt 不再是唯一通道。详细方案见 [`docs/TCP-MIGRATION-PLAN.md`](TCP-MIGRATION-PLAN.md)。

**分阶段迁移策略：**
1. Phase 1：Windows 端新增 bridge_agent.py TCP 服务，写入 queue.txt 复用现有 watcher
2. Phase 2：沙箱端 bridge_client.py，TCP 优先，queue.txt fallback
3. Phase 3：bridge_agent 直接 Named Pipe 分发，跳过 queue.txt
4. Phase 4（可选）：bridge_agent 替代 watcher 成为新主入口

---

## 双桥协同

代理桥和通信桥的组合让 Claude 的能力产生了质变：

| 能力维度 | 无桥 | 只有通信桥 | 只有代理桥 | 双桥齐全 |
|---------|------|-----------|-----------|---------|
| AI 对话 | 原生 Anthropic | 原生 Anthropic | xiaomi/zhipu 后端 | xiaomi/zhipu 后端 |
| 宿主机操作 | 不可能 | PowerShell/文件/进程 | 不可能 | PowerShell/文件/进程 |
| 服务管理 | 不可能 | start/stop/restart | 不可能 | start/stop/restart |
| 自动化任务 | 不可能 | watcher 定时执行 | 不可能 | watcher 定时执行 |
| 成本控制 | Anthropic 定价 | 不变 | xiaomi/zhipu 更便宜 | xiaomi/zhipu 更便宜 |
| 模型选择 | 固定 | 固定 | sonnet/opus/haiku 路由 | sonnet/opus/haiku 路由 |
| 思考模式 | adaptive (原生) | adaptive (原生) | adaptive (透传) | adaptive (透传) |

### 典型工作流

```
用户请求 → Claude 判断需要什么操作
  │
  ├─ 需要 AI 推理 → 代理桥 → xiaomi mimo-v2.5-pro → 流式响应
  │
  ├─ 需要执行命令 → 通信桥 → TCP/queue.txt → watcher → worker → 结果
  │
  ├─ 需要读写文件 → 直接 VM 内操作 (Read/Write/Edit tools)
  │
  └─ 组合操作 → 代理桥推理 + 通信桥执行 + 文件操作，多轮交替
```

### 结果等待方式

当前支持两种方式：

**方式一：TCP 直连（规划中，见 TCP-MIGRATION-PLAN.md）**
```bash
# 未来：直接 TCP 发送命令，同步等待响应
python3 bridge_client.py '{"command":"echo hello","type":"powershell","timeout":30}'
```

**方式二：文件轮询（当前）**
```bash
# 1. 提交命令
echo '{"state":"pending","cmd_id":"test_1","command":"echo hello","type":"process","timeout":30}' > queue.txt

# 2. 100ms 轮询等待结果
python3 bridge_wait.py test_1 30
```

---

### Provider 管理 (V13+)

一键切换脚本位于 `watcher/switch_provider.py`：

```bash
# 切换到 GLM
python switch_provider.py zhipu

# 切回小米
python switch_provider.py xiaomi

# 查看当前状态
python switch_provider.py status
```

也可直接调用 HTTP 接口：
```bash
curl -X POST http://127.0.0.1:4000/admin/provider -H "Content-Type: application/json" -d '{"provider":"zhipu"}'
curl http://127.0.0.1:4000/admin/status
```

切换行为：即时生效 + 持久化到 config.yaml + 自动更新路由规则 + 重置熔断器。

---

## 配置与运维

### 代理桥
- 配置：`D:\zebbingo\tools\claude-desktop-config\proxy\config.yaml`
- 日志：`proxy_debug.log` (详细), `proxy_audit.log` (结构化)
- 重启：通过通信桥发 `restart_proxy.ps1` 或 `force_restart_proxy.ps1`

### 通信桥
- 队列：`D:\zebbingo\tools\claude-bridge\watcher\queue.txt`
- 结果：`watcher\r_{cmd_id}.json`
- 日志：`watcher\watcher.log`
- Worker：`worker_factory.ps1 -DeployAll`
- TCP 迁移方案：`docs/TCP-MIGRATION-PLAN.md`

### 互相依赖
- 代理桥可以通过通信桥重启
- 通信桥不依赖代理桥
- 两者独立运行，互不干扰

---

## 变更记录

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-06-05 | V1.0 | 初始版本：双桥架构文档，包含代理桥 V13 全部修复记录和通信桥 V2.2 测试结果 |
| 2026-06-05 | V1.1 | 新增 bridge_wait.py 结果等待方式（100ms 轮询替代固定 sleep）；新增代理 vs 直连 A/B 对比基准数据 |
| 2026-06-05 | V1.2 | 新增 V13+ 精细化运营：429 熔断降级、thinking display 透传、OpenAI 路径 thinking 修复、`/admin/provider` 一键热切换、STREAM_TIMING 粒度化日志、TUN 模式排查 |
| 2026-06-06 | V1.3 | **沙箱架构升级**：更新架构图反映 tap0 网络（`--unshare-net` 已移除），新增跨 VM 延迟基准数据，新增 TCP 迁移路线图和 `TCP-MIGRATION-PLAN.md` 引用，新增两桥代码质量评估 |
