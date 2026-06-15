# Claude Bridge — 使用速查手册

给 Cowork 沙箱内其他对话的快速参考。**看完就知道走哪条路。**

> **核心设计理念**：桥的设计目标是 **零轮询、即时返回**。
> 不要用 `time.sleep()` 循环等结果。用 TCP 直连或用 `bridge_sandbox_helper.py` 的封装。
> 桥有 15 workers + wsl_pool(2) = 17 个并行槽位。**所有命令都应该并发发，不是串行等**。

---

## 核心规则（一图决策）

```
你要跑的命令是?
  ├─ bash/WSL 命令 (echo A && echo B, cd /tmp, whoami, python script.py)
  │    → type: "wsl"       ← 走 wsl_pool 高速通道, ~5ms
  │
  ├─ Windows cmd 命令 (dir, ver, netstat, tasklist)
  │    → type: "cmd"       ← 走 cmd.exe, ~25ms
  │
  ├─ PowerShell 命令 (Get-Process, iwr, Write-Output)
  │    → type: "powershell" ← PS5.1, ~15ms fast_path
  │
  └─ 不确定 / 混合
       → type: "generic"   ← subprocess, ~150ms (慢,不建议)
```

**最重要的规则**: bash/WSL 命令用 `type: "wsl"`, 不是 `type: "cmd"`。`cmd.exe` 和 `bash` 是不同的 shell, 操作符行为不同。

---

## 常见坑

### 1. type=cmd 跑 bash 命令 → 操作符被 cmd 拦截

```
❌ {"type":"cmd", "command":"echo A && echo B"}
   → cmd.exe 执行, && 被规则引擎转义成 ^&^& (规则现已禁用但仍不推荐)

✅ {"type":"wsl", "command":"echo A && echo B"}
   → bash 执行, && 正常起效, wsl_pool 高速通道
```

### 2. type=powershell 中用 && → 语法错误

PS 5.1 不支持 `&&`。用 `;` 代替或用 type=wsl。

```
❌ {"type":"powershell", "command":"echo A && echo B"}
   → PS 报错: The token '&&' is not a valid statement separator

✅ {"type":"powershell", "command":"Write-Output A; Write-Output B"}
✅ {"type":"wsl", "command":"echo A && echo B"}
```

### 3. 没意识到有 TCP 直连 → 一直走 queue 文件桥

queue.txt 文件桥延迟 ~120-200ms, TCP 直连 ~5-15ms。检查你的 bridge_client 调用是否带了 `--fallback` 或者 BRIDGE_HOST 配置错误。

---

## 各通道实测延迟

| 通道 | 延迟 | 使用条件 |
|------|------|----------|
| **wsl_pool TCP** (沙箱直接 TCP :19850) | **~5ms** | 沙箱有 tap0 网卡时直连 |
| **wsl_pool via TCP proxy** (queue.txt → watcher → localhost → wsl_pool) | **~10ms** | 沙箱**无网**时的自动路由 (V3.5.1) |
| **pipe fast_path** (type=powershell) | **~17ms** | TCP 通道可用 |
| **pipe cmd** (type=cmd) | **~25ms** | TCP 通道可用 |
| **pipe subprocess** (type=generic) | **~150ms** | TCP 通道可用, 避免使用 |
| **queue fallback** (file bridge) | **~120ms** | TCP 不可用时的降级 |
| **纯文件桥** (旧) | **~200ms** | 最慢, 仅兜底 |

> **关键**: 即使沙箱 VM 没有 tap0 网络，watcher 会自动通过 `localhost:19850`
> (宿主机内部 TCP) 把 type=wsl 命令转发给 bridge_agent 的 wsl_pool。
> 你不需要做任何特殊处理——正常写 queue.txt 用 type=wsl 就行。

---

## 验证你在哪条路

从沙箱 VM 运行 Python TCP 测试:
```python
import json, socket
s = socket.socket(); s.settimeout(15)
s.connect(("172.16.10.254", 19850))  # bridge_agent on Windows host
s.sendall(json.dumps({
    "cmd_id": "test-001",
    "command": "echo FAST_PATH_OK && whoami",
    "type": "wsl",
    "timeout": 10
}).encode() + b"\n")
line = s.makefile("r").readline()
result = json.loads(line)
print(f"channel={result['dispatch_channel']} dur={result['duration_ms']}ms")
```

如果 `dispatch_channel` 是 `"wsl_pool"` 且 dur < 10ms → 你在高速通道。如果是 `"pipe"` 或 `"queue"` → TCP 连接有问题。

---

## bridge_agent 连接信息

- Host: `172.16.10.254` (Windows 宿主机, tap0 网关)
- Port: `19850` (bridge_agent TCP)
- Proxy: `localhost:4000` (AI API 代理, 和通信桥无关, 不要往这里发命令)

---

## 零轮询快速模式（正确用法）

### 用 bridge_sandbox_helper.py（推荐）

```python
import sys
sys.path.insert(0, "/sessions/.../mnt/claude-bridge")  # 按实际路径调整
from bridge_sandbox_helper import Bridge, exec, batch, health

b = Bridge()

# 查看当前路径
print(b.path_info())  # ('tcp_proxy', 'queue.txt → watcher → localhost TCP proxy')

# 单条命令 — 零轮询，即时返回
r = b.exec("echo hello && whoami && uname -r", type="wsl")
print(r.stdout)        # "hello\nroot\n5.15.x.x-microsoft..."
print(r.duration_ms)   # ~10ms (TCP proxy) 或 ~5ms (TCP direct)
print(r.channel)       # "wsl_pool"
```

### 旧方式 vs 新方式

```python
# ❌ 旧方式: 每条命令 sleep 等、串行跑、不检查路径
import json, time, os
for cmd in ["cmd1", "cmd2", "cmd3"]:
    write_queue(cmd)
    time.sleep(1)         # 盲等
    while True:
        time.sleep(0.1)   # 轮询
        if os.path.exists(result_file): break
    # 总耗时: 3 × (1s盲等 + N × 0.1s轮询) ≈ 4-6秒

# ✅ 新方式: 零轮询，batch 并发
results = b.batch([
    ("cmd1", "wsl", 10),
    ("cmd2", "wsl", 10),
    ("cmd3", "powershell", 10),
])
# 总耗时: max(10, 10, 17) ≈ 17ms
```

---

## 并发编排模式

### 模式 1: Batch — 一次性发 N 条，一起等结果

```python
b = Bridge()

# 三条完全独立的查询 — 并发发送，同时返回
results = b.batch([
    ("free -h && df -h /", "wsl", 10),           # 系统资源
    ("Get-Process | Sort-Object WS -Desc | Select -First 5", "powershell", 15),  # Windows 进程
    ("curl -s localhost:8765/api/health", "wsl", 10),  # 服务健康
])

for r in results:
    print(f"[{r.channel}] {r.duration_ms}ms: {r.stdout[:60]}...")
```

### 模式 2: Fan-out — 同一模板，不同参数

```python
# 检查 5 个服务端口
results = b.fanout(
    template="curl -s --connect-timeout 2 localhost:{PORT}/health 2>&1 || echo DOWN",
    params=[{"PORT": "8765"}, {"PORT": "5000"}, {"PORT": "8080"}, {"PORT": "3000"}, {"PORT": "9090"}],
)

# 5 条命令并发，总耗时 ≈ 最慢的那个 (~2000ms timeout)，不是 5×2000ms
for i, r in enumerate(results):
    port = [8765, 5000, 8080, 3000, 9090][i]
    print(f"  port {port}: {r.stdout.strip()[:40]}")
```

### 模式 3: Pipeline — 前一步输出传给下一步

```python
# 找最大的日志文件，然后统计行数
results = b.pipeline([
    ("find /var/log -name '*.log' -exec ls -S {} + 2>/dev/null | head -3", "wsl", 10),
    ("wc -l {PREV_STDOUT}", "wsl", 10),  # {PREV_STDOUT} = 上一步的 stdout
])

# 步骤 1 找到文件名 → 步骤 2 统计行数
```

### 模式 4: 混合编排 — 并行阶段 + 汇聚

```python
# Phase 1: 并行检查 3 个系统
phase1 = b.batch([
    ("systemctl is-active chatbot 2>/dev/null || echo inactive", "wsl", 5),
    ("Get-Service -Name 'Claude*' | Select Status,Name | Out-String", "powershell", 10),
    ("df -h /mnt 2>/dev/null | tail -1", "wsl", 5),
])

# Phase 2: 根据 Phase 1 结果做下一步
if "inactive" in phase1[0].stdout:
    b.exec("echo 'chatbot is DOWN, checking logs...' && tail -20 /tmp/chatbot.log 2>/dev/null", "wsl")
    b.exec("sudo systemctl restart chatbot 2>&1", "wsl", timeout=15)
```

---

## 设计原则

1. **永远不要 `sleep()`** — 用 `Bridge.batch()` 或 TCP 直连。sleep 浪费的是你自己的 token 时间。
2. **能用 batch 就不串行** — 15 workers + 2 wsl_pool = 17 并行槽。不用就浪费了。
3. **type=wsl 最快** — bash 命令永远用 `type: "wsl"`，走 wsl_pool ~5ms。
4. **先测路径再跑任务** — `b.path_info()` 告诉你当前用的是 TCP 直连还是 TCP proxy。如果显示 `file_only`，检查 BRIDGE_DIR 配置。
5. **bridge_sandbox_helper.py 在项目根目录** — 可以直接 `import` 或 `exec(open('...').read())`。

## 规则引擎概况 (V4)

规则引擎已清空。如果未来自动生成规则:
- 规则是**每 type 绑定**的 (不会跨 type 应用)
- 人工禁用的规则永不被自动重新激活
- 如果某条规则看起来有问题, 实验验证后手动删除

---

## 相关文档

- `docs/WSL_POOL.md` — wsl_pool 设计文档
- `docs/ARCHITECTURE.md` — 完整架构
- `docs/TCP-MIGRATION-PLAN.md` — TCP 迁移规划
- `bridge_agent/wsl_pool.py` — 实现
- `bridge_client.py` — 沙箱侧客户端 (连接复用 V3.5)
