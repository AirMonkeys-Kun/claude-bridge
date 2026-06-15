# Claude Bridge — 使用速查手册

给 Cowork 沙箱内其他对话的快速参考。**看完就知道走哪条路。**

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
| **wsl_pool** (type=wsl + TCP) | **~5ms** | 沙箱连 bridge_agent TCP :19850 |
| **pipe fast_path** (type=powershell + TCP) | **~17ms** | 同上, PS 脚本 |
| **pipe cmd** (type=cmd + TCP) | **~25ms** | 同上, cmd 命令 |
| **pipe subprocess** (type=generic + TCP) | **~150ms** | 同上, 避免使用 |
| **queue fallback** (any type + file) | **~120ms** | TCP 不可用时的降级 |
| **纯文件桥** (旧) | **~200ms** | 最慢, 仅兜底 |

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
