# 双桥架构 — 代理桥 + 通信桥

> 最后更新：2026-06-05 | 版本：V1.2

---

## 概述

Claude 在 Cowork 环境中通过两座"桥"突破了原本的能力边界：

1. **代理桥 (Proxy Bridge)** — localhost:4000，让 Claude 能使用非原生 AI 后端（xiaomi mimo、zhipu GLM），同时保持完整的 Anthropic API 兼容性
2. **通信桥 (Communication Bridge)** — watcher + queue.txt + worker pool，让 Claude 能在 VM 沙箱内执行宿主机操作（PowerShell、文件、进程管理等）

两座桥各司其职，组合起来使 Claude 从一个"只能聊天的 AI"变成了一个"能操作宿主机的全栈助手"。

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Cowork Desktop                               │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Claude Agent (本体)                                          │   │
│  │  • 对话推理 ← 走代理桥                                        │   │
│  │  • 工具调用 (Read/Write/Bash) ← 本地 VM 内操作                │   │
│  │  • 宿主机操作 ← 走通信桥                                      │   │
│  └──────────┬──────────────────────────┬────────────────────────┘   │
│             │                          │                            │
│     ┌───────▼───────┐          ┌───────▼───────┐                    │
│     │   代理桥       │          │   通信桥       │                    │
│     │ localhost:4000 │          │ queue.txt     │                    │
│     │ V13 server.py │          │ watcher V2.2  │                    │
│     └───────┬───────┘          └───────┬───────┘                    │
│             │                          │                            │
└─────────────┼──────────────────────────┼────────────────────────────┘
              │ HTTPS                    │ Named Pipes
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
**端口：** localhost:4000
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

### 代理 vs 直连 A/B 对比 (2026-06-05)

| 测试场景 | 总耗时 | 首块延迟 | 块间隔(avg) | 块间隔(max) | 输出tok | think len |
|---------|--------|---------|------------|------------|--------|-----------|
| 非流式简单 (xiaomi) | 2027ms | 2027ms | - | - | 17 | 31 |
| 流式简单 (xiaomi) | 4227ms | 6ms | 52ms | 307ms | 48 | 137 |
| 流式推理 (xiaomi) | 13357ms | 0ms | 76ms | 255ms | 457 | 442 |
| 流式+adaptive thinking (xiaomi) | 7453ms | 0ms | 73ms | 370ms | 296 | 114 |
| 流式代码生成 (xiaomi) | 7909ms | 0ms | 78ms | 490ms | 260 | 85 |
| 流式中文 (xiaomi) | 4492ms | 0ms | 65ms | 181ms | 111 | 141 |
| 多轮对话 (xiaomi) | 2303ms | 0ms | 73ms | 409ms | 33 | 131 |
| Haiku 模型 (zhipu) | 7170ms | 0ms | 120ms | 791ms | 56 | 0 |
| 长文生成 (xiaomi) | 15860ms | 0ms | 74ms | 477ms | 395 | 810 |
| 长文吞吐量 | - | - | - | - | 395 tok / 15.9s = 24.9 tok/s |

**结论：** 代理首块延迟 0-6ms，SSE 零开销直传。主要延迟来自后端模型（2-5s），
与直连 Anthropic 模式感受接近，差异在模型生成速度而非代理本身。

### 关键修复历程

1. **httpx 0.28.1 兼容** — `Response` 无 `__aenter__`，改用 `send(stream=True)` + `aclose()`
2. **Adaptive thinking 透传** — 不再强制转换为 `enabled` + 固定 budget
3. **GZipMiddleware 移除** — SSE 流不需要压缩
4. **`_sse_raw` 零拷贝** — 未修改事件直接转发原始 JSON 字符串
5. **浅层 sort_keys** — 减少 payload 处理 CPU 开销
6. **429 自动熔断降级** — quota exhausted 触发 failover，不再直接返回客户端
7. **Thinking display 透传** — 保留 `display` 字段（`"summarized"` / `"omitted"`）
8. **OpenAI 路径 thinking 修复** — thinking 配置正确加入 OAI payload
9. **一键热切换** — `POST /admin/provider` + `GET /admin/status`
10. **粒度化时序日志** — STREAM_TIMING + max_think_gap 区分模型思考 vs 网络延迟

---

## 通信桥 (Communication Bridge)

**位置：** `D:\zebbingo\tools\claude-bridge\`
**核心：** watcher.ps1 V2.2 + worker_factory.ps1 V2.2
**协议：** queue.txt 文件 IPC + Named Pipe 分发

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

### 测试验证

| 测试 | 结果 |
|------|------|
| echo/compute/datetime | 全部通过, 1-87ms |
| file-io (写+读+删) | 通过, 25ms |
| multiline output | 通过, 2ms |
| error handling | 通过, 正确捕获异常 |
| port-check | 通过, 940ms (Get-NetTCPConnection 较慢) |

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
  ├─ 需要执行命令 → 通信桥 → queue.txt → watcher → worker → 结果
  │
  ├─ 需要读写文件 → 直接 VM 内操作 (Read/Write/Edit tools)
  │
  └─ 组合操作 → 代理桥推理 + 通信桥执行 + 文件操作，多轮交替
```

### 结果等待方式（V1.1 新增）

不再使用固定 `sleep N` 猜测等待时间，改用 `bridge_wait.py` 轮询：

```bash
# 1. 提交命令
echo '{"state":"pending","cmd_id":"test_1","command":"echo hello","type":"process","timeout":30}' > queue.txt

# 2. 100ms 轮询等待结果（自动检测文件出现，立即返回）
python3 bridge_wait.py test_1 30
```

`bridge_wait.py` 位于 `watcher/bridge_wait.py`，基于 9P 文件系统 100ms 轮询，检测到结果文件后等 50ms flush grace period，然后输出完整 JSON 结果。

---

### Provider 管理 (V13+ 新增)

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
