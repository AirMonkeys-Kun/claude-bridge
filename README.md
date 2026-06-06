# Claude Bridge — 宿主机命令桥接系统

> 当前版本：V21 (watcher V2.2) | 最后更新：2026-06-06

## 总览

Claude Bridge 让 Cowork 沙箱内的 Claude Agent 能够执行 Windows 宿主机操作——PowerShell 命令、文件读写、进程管理、WSL 调用等。它与代理桥（localhost:4000，AI 模型 API 转发）共同构成 Claude 的"双桥"能力体系。

## 架构

```
┌──────────────────────────────────────────────────────────────┐
│                    Cowork 沙箱 (Linux VM)                     │
│                                                               │
│  Claude Agent                                                 │
│    │ 写入 queue.txt 或 TCP → 轮询/接收结果                     │
│    │ (当前: queue.txt 文件 IPC; 规划中: TCP 直连)              │
└────┬─────────────────────────────────────────────────────────┘
     │
┌────▼─────────────────────────────────────────────────────────┐
│  Windows 宿主机                                               │
│                                                               │
│  watcher.ps1 V2.2 (V21 async dispatch)                       │
│  ├─ FileSystemWatcher 事件驱动                                │
│  ├─ 规则引擎 V5 (命令变换/学习)                                │
│  ├─ inflight guard + content dedup                            │
│  └─ Named Pipe 异步分发到 typed workers                       │
│                                                               │
│  Worker Pool (14 workers, worker_factory V2.2)                │
│  ├─ generic ×4  (通用 PowerShell/cmd)                         │
│  ├─ file ×4     (文件读写、下载)                               │
│  ├─ process ×2  (进程管理)                                     │
│  ├─ system ×2   (系统级操作)                                   │
│  ├─ wsl ×1      (WSL 命令穿透)                                 │
│  └─ user ×1     (用户上下文操作)                                │
│                                                               │
│  Guardian V3 (60s 自动巡检 + 自愈)                             │
│  ├─ 监控 watcher 心跳                                          │
│  ├─ 监控 worker pool 存活                                      │
│  └─ 监控代理桥端口                                             │
└──────────────────────────────────────────────────────────────┘
```

## 快速启动

```powershell
# 一键启动（注册 Guardian + 部署 workers + 启动 watcher）
.\start_bridge.bat

# 一键重启（清理 + 重建 worker pool + 重启 watcher）
.\一键重启_完整版.bat
```

启动后系统完全自维持——Guardian 每 60 秒巡检，watcher 故障自动重启，无需人工干预。

## 使用方式

### 基本命令

写入 `watcher/queue.txt`：
```json
{"state":"pending","cmd_id":"my-cmd-001","command":"echo hello","type":"powershell","timeout":30}
```

读取结果 `watcher/r_my-cmd-001.json`：
```json
{"state":"done","cmd_id":"my-cmd-001","exit_code":0,"stdout":"hello\r\n","stderr":"","duration_ms":123,"timestamp":"..."}
```

### 命令类型

| type 值 | 执行方式 | 说明 |
|---------|---------|------|
| `powershell` / `p` | PowerShell ScriptBlock 快路径 | 推荐，~10ms 启动 |
| `cmd` | cmd.exe /c | 兼容旧命令 |
| `user` / `u` | 分发到 user worker | 用户上下文（MSIX 穿透、桌面文件） |
| `wsl` / `w` | 分发到 wsl worker | WSL 命令执行 |
| `file` / `f` | 分发到 file worker | 文件操作 |
| `process` / `p` | 分发到 process worker | 进程管理 |
| `system` / `s` | 分发到 system worker | 系统级操作 |

### 规则引擎

watcher 自动应用已知规则修正命令（如 cmd 模式 `&&` → `^&^&`）。规则存储在 `watcher/bridge_rules.json`，支持热更新。

## 核心文件

| 文件 | 说明 | 版本 |
|------|------|------|
| `watcher/watcher.ps1` | 主桥，事件驱动 + Named Pipe 分发 | V21 (V2.2) |
| `cluster/worker_factory.ps1` | Worker 生命周期管理 | V2.2 |
| `cluster/worker_generic.ps1` | 通用 worker 实现 | V4 |
| `cluster/rule_engine.ps1` | 规则引擎 | V5 |
| `cluster/guardian_v3.ps1` | 自愈巡检 | V3 |
| `start_bridge.bat` | 一键启动入口 | V21 |
| `watcher/queue.txt` | 命令队列（JSON） | — |
| `watcher/r_{cid}.json` | 命令结果文件 | — |

## 详细文档

| 文档 | 内容 |
|------|------|
| [BRIDGE.md](BRIDGE.md) | 通信桥完整技术文档（协议、配置、已知问题、回归测试） |
| [docs/dual-bridge-architecture.md](docs/dual-bridge-architecture.md) | 双桥架构总览（代理桥 + 通信桥能力对比、性能基准） |
| [docs/EVOLUTION.md](docs/EVOLUTION.md) | V1 → V21 完整演化历史 |
| [docs/TCP-MIGRATION-PLAN.md](docs/TCP-MIGRATION-PLAN.md) | TCP 通道迁移方案（queue.txt → TCP 直连） |
| [docs/PHASE3-DIRECTIVE.md](docs/PHASE3-DIRECTIVE.md) | Phase 3 直做指令（bridge_agent.py 直连 Named Pipe） |
| [docs/MODULE-REUSE-INDEX.md](docs/MODULE-REUSE-INDEX.md) | V18 模块复用价值索引 |
| [docs/self-evolve-log.md](docs/self-evolve-log.md) | 自巡检日志 |

## 版本历史

| 版本 | 关键特性 |
|------|---------|
| V21 (V2.2) | Named Pipe 异步并发分发、自升级检测、hostLoopMode 修复、Guardian 三层自愈 |
| V19 | Typed worker dispatch via Named Pipe |
| V17 | ScriptBlock 快路径 (~10ms vs ~150ms 子进程) |
| V15 | FileSystemWatcher 替代 EventWaitHandle |
| V11 | 自学习规则引擎 + 错误收集 + PID 锁 |
