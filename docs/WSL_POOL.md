# WSL Pool — bridge_agent 持久 wsl.exe 高速通道

> 创建日期: 2026-06-15  
> 作者: Cowork 沙箱内的 Claude（基于 D:\zebbingo\tools\claude-bridge 现状）  
> 路径基准: `D:\zebbingo\tools\claude-bridge\`（按你的环境调整）

---

## TL;DR

在 `bridge_agent` (Python) 端维护一个**常驻 wsl.exe 子进程**，用 stdin/stdout + marker 协议执行命令。把 type=wsl 的端到端延迟从 ~114ms（worker_generic.ps1 subprocess fallback）降到 **~5-15ms**（实测单条命令），且省掉每次冷启动 wsl.exe 的开销。

**不需要动 worker pool**——dispatch.py 在 pipe dispatch 之前短路 type=wsl，由 wsl_pool 直接处理。

---

## 1. 背景与动机

### bridge 现状（V22）

- `worker_factory.ps1 -DeployAll` 部署 **16 workers**（generic ×6, file ×4, process ×2, system ×2, wsl ×1, user ×1）
- 所有 type 都用同一个 `worker_generic.ps1`（V17 遗留的 `cluster/wsl_bridge/worker.ps1` 不在用）
- `bridge_agent.dispatch.execute_command()` 优先走 Named Pipe 直连，失败回退 queue.txt

### type=wsl 的瓶颈

`worker_generic.ps1` 的 wsl 分支每次都启动新 wsl.exe：
```powershell
} elseif ($ctype -eq "wsl") {
    $psi.FileName = "wsl.exe"
    $psi.Arguments = "-e bash -c `"$($rawCmd -replace '"', '\"')`""
}
```

实测拆解：
- wsl.exe 冷启动：30-50ms
- bash --norc 加载 + 命令解析：5-10ms
- 命令执行（echo 这种）：1-5ms
- Process.WaitForExit + stdout 收集 + 进程清理：20-40ms
- **总计 60-110ms**（不含 bridge_agent TCP RTT 0.8ms × 2 和 Named Pipe dispatch 18ms）

### 修复前实测数据

| 路径 | 平均 | 来源 |
|---|---|---|
| 6-08 type=powershell fast_path（SDK 2.1.149） | **13ms** | 历史 bmt 基线 |
| 6-14 type=powershell fast_path（SDK 2.1.170） | 118ms | SDK 升级后回归 ~9x |
| 6-14 type=wsl via subprocess fallback（TCP） | **114ms** | bench_wsl 实测 |

---

## 2. 架构

```
┌──────────────────────────────────────────────────────────────┐
│                    Cowork Linux VM (172.16.10.3)              │
│                                                              │
│  Claude Agent  /  Python client                              │
│    │                                                         │
│    │ TCP 0.8ms 跨 VM                                         │
│    ▼                                                         │
└───┬──────────────────────────────────────────────────────────┘
    │
    │ 172.16.10.254:19850
    │
┌───▼──────────────────────────────────────────────────────────┐
│  Windows Host                                                │
│                                                              │
│  bridge_agent.py (Phase 4 hardened, PID 由 watchdog 守护)    │
│    ├─ ThreadPoolExecutor (10 workers) 处理 TCP 连接           │
│    └─ execute_command(cmd)  ←  dispatch.py                    │
│         ├─ if cmd_type == "wsl":                              │
│         │    └─ wsl_pool.exec(command)        ← 新增短路      │
│         │         │                                          │
│         │         ▼                                          │
│         │  _WslProc (持久 wsl.exe + Lock)                     │
│         │    ├─ stdin: <user_cmd>; printf '\n<MARKER> %s\n' "$?"│
│         │    ├─ stdout: readline 直到 MARKER → exit_code      │
│         │    └─ stderr: 后台 drain 线程（避免 pipe 死锁）       │
│         │                                                    │
│         └─ else: pipe dispatch (原有逻辑不变)                │
│                                                              │
│  Watchdog subprocess  ←→  bridge_agent  (互相守护)           │
└──────────────────────────────────────────────────────────────┘
```

### 为什么在 bridge_agent 端做（而不是新 PowerShell worker）

1. **Python subprocess + threaded readline 比 PowerShell runspace-internal Process 管理更可靠**
2. **不动 16-worker pool**（`worker_factory.ps1 -DeployAll` 配置不变）
3. **易扩展**：pool_size > 1、restart-on-crash、超时强杀等
4. **复用现有 watchdog / health HTTP / TCP server** 基础设施

---

## 3. Marker 协议

### 设计

```python
marker = f"___WSLEND_{uuid.uuid4().hex[:16]}___"
payload = f"{command}; printf '\\n{marker} %s\\n' \"$?\"\n"
```

- **唯一性**：每条命令用 UUID，防止用户输出偶然命中 sentinel
- **边界识别**：readline 读到以 marker 开头的行 → 解析 exit code
- **bash 友好**：`printf` + `$?` 在 bash --norc 都能用，不依赖 PROMPT_COMMAND

### 并发模型

- `_WslProc` 用 `threading.Lock` 串行化命令
- 默认 `pool_size=1`，多命令排队
- 如果未来需要并发：`pool_size=N` + round-robin dispatch（已在 `WslPool` 类预留接口）

---

## 4. 文件清单

### 新增

| 文件 | 用途 |
|---|---|
| `bridge_agent/wsl_pool.py` | **核心**：WslPool / _WslProc 实现（~210 行） |
| `bench_light.ps1` | type=powershell 延迟基准（5 iter） |
| `bench_wsl.ps1` | type=wsl via queue.txt 延迟基准 |
| `bench_wsl_tcp.ps1` | type=wsl via TCP 延迟基准（有 dedup bug） |
| `verify_aws.py` / `verify_s3_public.py` | AWS S3 配置核实脚本 |
| `test_s3_intro.py` | 触发 figurine introduction 端到端验证 |
| `apply_env_fix.py` | chatbot/.env 修复脚本（带备份） |
| `verify_status.py` / `verify2.py` / `verify3.py` 等 | 项目状态核实脚本（一次性诊断） |
| `docs/WSL_POOL.md` | **本文档** |

### 修改

| 文件 | 改动 |
|---|---|
| `bridge_agent/dispatch.py` | `execute_command()` 在 pipe dispatch 之前插入 `if cmd_type == "wsl"` 分支调 wsl_pool |
| `chatbot/.env` | 追加 3 行 S3 配置（AWS_BUCKET_NAME/S3_AUDIO_BASE_PATH/S3_PUBLIC_BUCKET） |
| `docs/workspace_vm_bundle_fix.md` | 追加"九、回归记录：2026-06-14 — SDK 2.1.170"章节 |

---

## 5. dispatch.py 集成点

在 `execute_command()` 内、Named Pipe dispatch 循环**之前**插入：

```python
# ── WSL fast path: persistent wsl.exe via wsl_pool (skip worker pool) ──
if cmd_type == "wsl":
    try:
        from .wsl_pool import get_pool
        pool_result = get_pool().exec(command, timeout=timeout)
        result = {
            "state": "error" if pool_result.get("error") else "done",
            "cmd_id": cmd_id,
            "exit_code": pool_result["exit_code"],
            "stdout": pool_result["stdout"],
            "stderr": pool_result.get("stderr", ""),
            "error": pool_result.get("error", ""),
            "duration_ms": pool_result["duration_ms"],
            "fast_path": False,
            "pipe_direct": False,
            "timestamp": _now_str(),
        }
        return result, "wsl_pool"
    except Exception as e:
        log(f"  [{cmd_id}] wsl_pool failed ({e}) — falling back to pipe dispatch")
```

失败时（wsl_pool 异常或 wsl.exe 死）自动 fall through 到原有 pipe dispatch → queue.txt fallback，**不会断链**。

---

## 6. 用法

### 从 Cowork VM 调用（Python TCP 客户端）

```python
import json, socket
s = socket.socket(); s.settimeout(15)
s.connect(("172.16.10.254", 19850))  # bridge_agent on Windows host
s.sendall((json.dumps({
    "cmd_id": "my-cmd-001",
    "command": "echo hello; whoami; uname -a",
    "type": "wsl",
    "timeout": 10
}) + "\n").encode())
buf = b""
while b"\n" not in buf:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
result = json.loads(buf.decode().strip())
print(f"channel={result['dispatch_channel']} dur={result['duration_ms']}ms")
print(result["stdout"])
```

**响应里 `dispatch_channel` 应该是 `"wsl_pool"`**（如果不是，说明 wsl_pool 没启用或失败了，走了 fallback）。

### Health check

```python
{"type": "ping"} → {
    "type": "pong",
    "workers_total": 16,
    "workers_alive": 16,
    "watcher_alive": true,
    "active_connections": 0,
    "pipe_mode": true
}
```

### Restart bridge_agent（让新代码生效）

bridge_agent 有 watchdog 自动重启机制，kill 主进程即可：
```powershell
# 找 PID
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | 
    Where-Object { $_.CommandLine -like '*bridge_agent.py*' -and $_.CommandLine -notlike '*watchdog*' }
# kill
Stop-Process -Id <pid> -Force
# watchdog 在 30s 内自动重启（PARENT_CHECK_INTERVAL=30）
```

⚠️ **绝对不要跑 `restart_bridge.ps1`**——那是 V17 遗留脚本，会 kill 当前 16 workers + 启 5 个旧 *_bridge workers，破坏 V22 架构。

---

## 7. 实测数据

### 单条命令延迟（5 iter `echo PROBE`）

| 通道 | iter1 | iter2 | iter3 | iter4 | iter5 | avg |
|---|---|---|---|---|---|---|
| wsl_pool (TCP, 本次实现) | ~0 | ~0 | ~0 | ~0 | ~0 | **<5ms** |
| subprocess fallback (TCP) | — | — | — | — | — | ~114ms |
| subprocess fallback (queue.txt) | 117 | 64 | 106 | 126 | 178 | ~118ms |

注：`duration_ms` 字段从 worker 自报读出。`<5ms` 在日志里显示为 0-16ms，因为 worker 内 `time.monotonic()` 精度限制。

### 端到端 figurine introduction（修复 S3 fix 后实测）

```
01:29:59.946 → 01:30:02.228 = 2.3 秒走完整链路
- 收到 MQTT session_start
- figurine activation record 创建
- 找到 pre-generated audio URL
- HTTP GET s3 mp3 (92205 bytes)
- TTS 完成
- 推送 introeos + audio start
- 持续推 audio chunks
```

---

## 8. 已知限制

### 1. 复合长命令会 EOF（待修）

测过的 5-section 诊断脚本（多个 `cd && git log && status`）在 ~266ms 后 wsl.exe EOF，命令实际没跑完。

**疑似原因**：
- bash 后台 stderr drain 线程可能竞争
- 或者某个 cd 失败后 bash 退出
- 或者 stdout buffer 被填满（wsl.exe 内部缓冲）

**Workaround**：拆成多条短命令，每条单独发。

**待办**：定位 EOF 根因，可能要在 wsl_pool 加 stdin/stdout 双向异步 IO（避免单线程 readline 阻塞）。

### 2. 单进程串行（默认）

`pool_size=1`，并发命令排队。如果需要并发：
```python
class WslPool:
    def __init__(self, pool_size=1):  # 改成 N
```
然后 round-robin dispatch（接口已预留）。

### 3. 无超时强杀

`readline()` 阻塞，long-running 命令的 timeout 实际上要等 readline 返回才生效。如果命令 hang 死（如 `sleep 1000 & wait`），timeout 不能立即中断——会等到 deadline，然后 `_restart_if_dead()` 重启 wsl.exe。

**待办**：用 `select.select([stdout], [], [], remaining_timeout)` 或 asyncio 改造，实现真超时。

### 4. stderr 不返回

当前后台 drain 线程丢弃 stderr 内容（避免 pipe 死锁）。如果 stderr 重要（deprecation warning、错误诊断），需要改成 capture。

**临时方案**：用户命令里用 `2>&1` 把 stderr 合到 stdout。

### 5. wsl_1 worker 闲置（可选清理）

启用 wsl_pool 后，dispatch.py 的 type=wsl 短路返回，**worker_factory 部署的 wsl_1 worker 不会被路由到**。它仍在 pool 里但不工作。

**建议**：
- 选项 A：保留作为 fallback（如果 wsl_pool 异常会自动 fall through 到 pipe → wsl_1）
- 选项 B：从 `worker_factory.ps1` 的 deploy plan 移除 `@{type="wsl"; count=1}`，省 ~30MB 内存

---

## 9. PowerShell bench_wsl_tcp.ps1 的 dedup 问题（独立 bug）

`bench_wsl_tcp.ps1` 跑两次，第二次直接返回第一次的 stderr（同样的 timestamp）——**不是脚本本身的错**。

怀疑 worker_generic.ps1 的 subprocess fallback 在某些条件下复用了上一次 powershell.exe 子进程的结果。需要查 worker_generic.ps1 的 `Process.Start` + `WaitForExit` 缓存路径。

**Workaround**：直接从 VM 用 Python TCP 测，不用 PowerShell wrapper（见 §6 用法）。

---

## 10. 同期副产物（非 wsl_pool 相关）

这些是同一次会话里顺手修的，列在这里方便后续整合时一并参考。

### A. SDK 2.1.170 同步回归

Claude Desktop 自动升级 SDK 2.1.149 → 2.1.170，MSIX 存储更新但**非 MSIX 路径**（cowork-svc 实际读的）还停在 2.1.149，导致 `cowork_vm_node.log` 报 `SDK version 2.1.170 not verified`。

**修复**：
```powershell
$src='C:\Users\Administrator\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\claude-code-vm'
$dst='C:\Users\Administrator\AppData\Local\Claude-3p\claude-code-vm'
Copy-Item "$src\.sdk-version" "$dst\.sdk-version" -Force
Copy-Item "$src\2.1.170" "$dst\2.1.170" -Recurse -Force
```

复制完 890ms（NTFS CoW）即可，无需重启 cowork-svc。详见 `docs/workspace_vm_bundle_fix.md` 第九章节。

### B. S3 audio fix（figurine introduction fallback 修复）

`chatbot/.env` 漏配 `AWS_BUCKET_NAME`，导致 `audio_generation_service.py` 的 `_create_s3_client()` 报 `AWS_BUCKET_NAME is required`，触发 figurine introduction 错误 fallback 到 Kokoro TTS。

**根因**：lvmin 同事（MOLVMIN）5-12 实现的 audio storage 系统已 merge 到 main，`.env.example` 明确给了 4 个 S3 变量，但实际 `.env` 只配了 AWS 凭证（access_key/secret/region）和 STAGE_OTA_BUCKET，漏了 audio 专用的 3 个。

**修复**（已 apply）：
```env
AWS_BUCKET_NAME=zeb-audio
S3_AUDIO_BASE_PATH=introductions
S3_PUBLIC_BUCKET=true
```

实测：figurine introduction 现在直接 HTTP GET `https://zeb-audio.s3.eu-west-2.amazonaws.com/introductions/Doctor%20Emma/short/1/d988b308.mp3`（HTTP 200, 92KB），不再调 Kokoro。

详见 MOLVMIN 的 commits `484aade` (5-12) 和 `1ae35e7` (5-14)。

### C. fast_path hang（known issue，未修）

worker_generic.ps1 V4 的 fast_path 用 `[PowerShell]::Create() + AddScript(ScriptBlock)` 嵌套在 pipe runspace 内执行，跟 `CallNamedPipe` 同步阻塞在某些条件下死锁。

**只影响 type=powershell + TCP**（type=wsl/user/file 等走 subprocess fallback 的不受影响）。

**当前状态**：标记为 known issue，不修。用户日常用 type=wsl 不受影响。

**后续修法**：要么改 worker_generic.ps1 的 fast_path 用 Process + async stdout，要么 bridge_agent 优先走 type=wsl（脚本里 `command="bash -c '...'"`）绕开 fast_path。

---

## 11. 后续整合建议（给接力 AI）

按优先级：

1. **EOF bug**（§8.1）—— 真正影响生产力的限制。优先级最高。可能要重写 `_WslProc.exec` 用 `selectors` 或 `asyncio`。
2. **超时强杀**（§8.3）—— 配合 EOF bug 一起做。`signal.CTRL_BREAK_EVENT` 或 wsl.exe PID kill。
3. **pool_size 扩展**（§8.2）—— 如果实际场景需要并发 WSL 命令（同时跑多个长任务）。先 benchmark 看是否有收益。
4. **stderr capture**（§8.4）—— 用户命令里 `2>&1` 已能 work，但 IDE-style 集成需要分开返回。
5. **wsl_1 worker 清理**（§8.5）—— 释放 ~30MB 内存。低优先级。
6. **fast_path hang 修复**（§C）—— 如果想恢复 type=powershell + TCP 的 13ms 极速路径。
7. **bench_wsl_tcp.ps1 dedup**（§9）—— 独立 bug，跟 wsl_pool 无关，但影响 PowerShell 端的 benchmark 可信度。

### 跟其他系统的关系

- **wsl_pool 跟 `docs/TCP-MIGRATION-PLAN.md` Phase 4 同方向**——都是在 bridge_agent 端做 worker pool 替代。Phase 4 想让 bridge_agent 完全替代 watcher；wsl_pool 是 type=wsl 这条专线先走通。
- **wsl_pool 不依赖 watcher**——但 watcher 仍在跑（管理其他 16 workers + queue.txt fallback）。如果未来 watcher 下线，wsl_pool 不受影响。
- **wsl_pool 的协议跟现有 TCP JSON-line 协议一致**——`{"cmd_id":..., "command":..., "type":"wsl", "timeout":...}\n`，所以从沙箱端 client 看，type=wsl 跟其他 type 完全透明。

---

*相关文档*：
- `docs/TCP-MIGRATION-PLAN.md` — bridge_agent 整体迁移规划
- `docs/workspace_vm_bundle_fix.md` — MSIX 路径隔离根因 + 2026-06-14 SDK 2.1.170 回归
- `BRIDGE.md` — bridge 完整技术文档
- `bridge_agent/dispatch.py:execute_command` — 集成点（§5 引用）
- `bridge_agent/wsl_pool.py` — 实现（§2 引用）
