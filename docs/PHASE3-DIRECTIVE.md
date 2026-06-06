# Phase 3 直做指令 — bridge_agent.py

> 日期：2026-06-06 | 总指挥对话产出
> 给下一个实现会话的指令：跳过 Phase 1-2，直接实现 Phase 3
> 前提文档：TCP-MIGRATION-PLAN.md、MODULE-REUSE-INDEX.md

---

## 为什么跳过 Phase 1-2

原方案 Phase 1 是 bridge_agent.py 写 queue.txt，只是把文件操作从沙箱搬到 Windows。
Phase 2 是沙箱端客户端。两步做完延迟改善有限（queue.txt → FSW → watcher 链路没变）。

**Phase 3 直做的理由：**
- V18 modules/pipe-dispatcher.ps1 已有完整的 Named Pipe 客户端协议（管道名、JSON 格式、连接超时）
- V21 的 `.worker_pool.json` 已经记录了所有 worker 的 pipe 名称
- Named Pipe 是 Windows 原生 IPC，Python 通过 pywin32 或 subprocess 调用即可
- 不需要改 watcher.ps1，不需要改 worker，只是加一个并行的 TCP → Named Pipe 网关

---

## 实现规格

### 新增文件

| 文件 | 位置 | 职责 |
|------|------|------|
| bridge_agent.py | `D:\zebbingo\tools\claude-bridge\bridge_agent.py` | TCP 服务端，接收命令，直连 Named Pipe 分发 |
| bridge_client.py | `D:\zebbingo\tools\claude-bridge\bridge_client.py` | TCP 客户端（部署到沙箱），带 queue.txt fallback |

### bridge_agent.py 设计

```
TCP Server (0.0.0.0:19850)
    │
    │  接收命令 JSON
    ▼
Worker 选择器
    │ 读 .worker_pool.json
    │ 按 type 选最空闲 worker
    ▼
Named Pipe 客户端
    │ 连接 Cluster_Wkr_{type}_{n}
    │ 发送: {"id":"cid","c":"cmd","t":"type","to":30}
    │ 接收: ACK {"id":"cid","ack":true}
    ▼
结果轮询器
    │ 每 100ms 检查 watcher/r_{cid}.json
    │ 等到 state=done 或 timeout
    ▼
TCP 响应
    │ 返回完整结果 JSON 给客户端
    ▼
完成
```

### 关键协议细节（来自 V18 pipe-dispatcher + V21 watcher）

**Named Pipe 命令格式（发到 worker）：**
```json
{"id":"cmd_001","c":"echo hello","t":"powershell","to":30}
```

**Worker ACK（立即返回）：**
```json
{"id":"cmd_001","ack":true}
```

**结果格式（worker 写到 `watcher/r_{cid}.json`）：**
```json
{
  "state": "done",
  "cmd_id": "cmd_001",
  "exit_code": 0,
  "stdout": "hello\r\n",
  "stderr": "",
  "error": "",
  "duration_ms": 123,
  "timestamp": "2026-06-06 10:00:00"
}
```

**TCP 请求（沙箱 → Windows）：**
```json
{"cmd_id":"cmd_001","command":"echo hello","type":"powershell","timeout":30}
```

**TCP 响应（Windows → 沙箱）— 直接转发 r_{cid}.json 内容**
```json
{"state":"done","cmd_id":"cmd_001","exit_code":0,"stdout":"hello\r\n","stderr":"","error":"","duration_ms":123,"timestamp":"..."}
```

### Worker Pool 发现

从 `D:\zebbingo\tools\claude-bridge\cluster\.worker_pool.json` 读取：
```json
{
  "workers": [
    {"id": "generic_1", "type": "generic", "pipe": "Cluster_Wkr_generic_1"},
    {"id": "file_1", "type": "file", "pipe": "Cluster_Wkr_file_1"},
    ...
  ]
}
```

### Named Pipe 连接（Python 实现）

方案 A（推荐）：用 `win32pipe.CallNamedPipe` 同步调用
```python
import win32pipe
import json

def dispatch_to_worker(pipe_name, cmd_json_str, timeout_ms=30000):
    result = win32pipe.CallNamedPipe(
        r"\\.\pipe\" + pipe_name,
        cmd_json_str.encode('utf-8'),
        65536,  # buffer size
        timeout_ms
    )
    return json.loads(result.decode('utf-8'))
```

方案 B（备选）：subprocess 调用 PowerShell 片段
```python
# 如果 pywin32 不可用
result = subprocess.run([
    'powershell', '-NoProfile', '-Command',
    f'$p = New-Object IO.Pipes.NamedPipeClientStream(".","{pipe_name}",[IO.Pipes.PipeDirection]::InOut);'
    f'$p.Connect(200);'
    f'$w = New-Object IO.StreamWriter($p); $w.AutoFlush=$true;'
    f'$r = New-Object IO.StreamReader($p);'
    f'$w.WriteLine(\'{cmd_json}\'); $r.ReadLine()'
], capture_output=True, text=True, timeout=30)
```

### Fallback 链

```
1. 尝试 Named Pipe 直连 worker
   │ 失败？
   ▼
2. 尝试写 queue.txt（传统路径）
   │ 失败？
   ▼
3. 返回错误
```

---

## bridge_client.py 设计

```python
# 沙箱端使用
import socket, json

def send_command(cmd, host="172.16.10.1", port=19850, timeout=35):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.sendall((json.dumps(cmd) + '\n').encode())
        result = b''
        while True:
            chunk = s.recv(65536)
            if not chunk: break
            result += chunk
            if b'\n' in result: break
        s.close()
        return json.loads(result.decode())
    except (ConnectionRefused, TimeoutError):
        # Fallback: 写 queue.txt + 轮询 r_{cid}.json
        return fallback_file_bridge(cmd)
```

---

## 验证清单

- [ ] bridge_agent.py 启动，TCP 端口 19850 可连接
- [ ] 发送 echo 命令 → Named Pipe 分发到 worker → 结果通过 TCP 返回
- [ ] echo roundtrip < 30ms（vs 旧 160ms）
- [ ] 并发 5 命令全部成功
- [ ] worker 故障时自动跳过，选下一个 worker
- [ ] 所有 worker 都不可用时 fallback 到 queue.txt
- [ ] bridge_client.py 在沙箱内可用
- [ ] TCP 连接失败时自动 fallback 到 queue.txt

---

## 参考文件

| 文件 | 用途 |
|------|------|
| `modules/pipe-dispatcher.ps1` | Named Pipe 客户端协议参考 |
| `modules/result-collector.ps1` | 结果 JSON 格式参考 |
| `watcher/watcher.ps1` L418-474 | V21 Dispatch-ToWorker 逻辑 |
| `cluster/.worker_pool.json` | Worker pool 发现 |
| `docs/TCP-MIGRATION-PLAN.md` | 完整迁移方案 |
| `docs/MODULE-REUSE-INDEX.md` | V18 模块复用分析 |
