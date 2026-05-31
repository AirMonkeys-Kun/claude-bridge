# Claude Bridge — Windows 命令桥接系统

## 总览

Claude Bridge 是一个 **文件队列驱动的 Windows 命令执行系统**，用于在 Windows 和 WSL 之间桥接命令执行。当 Claude 在 WSL/Linux 环境中需要执行 Windows 端的命令时，通过本系统实现。

## 架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Windows 宿主机                             │
│                                                                  │
│  [桥目录]/                                                       │
│  ┌──────────────────────────────────────────────────┐            │
│  │  queue.txt            ← JSON 命令队列              │            │
│  │  watcher.ps1          ← 轮询队列并执行命令         │            │
│  │  watchdog.bat         ← 监控 watcher 是否存活      │            │
│  │  restart_watchdog.bat ← 重启 watchdog 入口         │            │
│  │  Start-Bridge.ps1     ← 手动启动桥入口             │            │
│  │  r_{cmd_id}.json      ← 命令执行结果文件           │            │
│  │  bridge_rules.json    ← 规则引擎（自学习积累）      │            │
│  │  error_history.json   ← 错误历史（模式分析）        │            │
│  │                                                              │
│  └──────────────────────────────────────────────────┘            │
│                                                                  │
│    cmd.exe /c ...   ← type:"cmd"                                 │
│    powershell.exe   ← type:"powershell"                          │
│    wsl -e bash ...  ← type:"powershell" (推荐) 或 type:"cmd"     │
└─────────────────────────────────────────────────────────────────┘
         │
         │ (通过 queue.txt 文件写入)
         │
┌─────────────────────────────────────────────────────────────────┐
│                      Claude (WSL / 会话)                          │
│                                                                  │
│  · 写入 queue.txt → 设置 state=pending                          │
│  · 轮询结果文件 r_{cmd_id}.json 直到 state=done                   │
│  · 读取 stdout/stderr 获取执行结果                                │
│  · 分析错误 → 更新 bridge_rules.json → 越用越智能                │
└─────────────────────────────────────────────────────────────────┘
```

## 文件清单

| 文件 | 说明 | 版本 |
|------|------|------|
| `watcher.ps1` | 核心轮询器，每 200ms 扫描 queue.txt | v11 |
| `watchdog.bat` | 守护进程，每 10s 检测 heartbeat，发现挂起则重启 | v3 |
| `Start-Bridge.ps1` | 手动启动桥（停止旧 watcher + 启动新 watcher） | — |
| `start_bridge_hidden.bat` | 隐藏窗口方式启动 watcher | — |
| `restart_watchdog.bat` | 重启 watchdog（杀死旧 + 清理僵尸 + 启动新） | — |
| `queue.txt` | 命令队列文件（JSON 格式） | — |
| `watcher.log` | watcher 运行日志 | — |
| `watchdog.log` | watchdog 运行日志 | — |
| `bridge_rules.json` | **规则引擎** — 存储已知错误模式及自动修复规则 | v1 |
| `error_history.json` | **错误历史** — 自动记录执行异常供分析 | v1 |

## 使用方式

### 执行 Windows 命令

1. 写入 `queue.txt`：
   ```json
   {"state":"pending","cmd_id":"my-cmd-001","command":"echo hello","type":"cmd"}
   ```

2. watcher 自动检测到 `state=pending` → 执行命令 → 写入结果到 `r_my-cmd-001.json`

3. 读取结果文件：
   ```json
   {"state":"done","cmd_id":"my-cmd-001","exit_code":0,"stdout":"hello\n","stderr":"","duration_ms":123}
   ```

### 执行 WSL 命令（推荐方式）

```json
{"state":"pending","cmd_id":"wsl-test","command":"wsl -e bash -c 'echo hello; whoami; ls /home/'","type":"powershell"}
```

**重要：** WSL 命令建议用 `type:"powershell"` + 单引号包裹 bash 参数，避免 cmd.exe 的转义问题。

### 常用操作

```powershell
# 启动桥（手动）
.\Start-Bridge.ps1

# 启动 watcher 隐藏窗口
start_bridge_hidden.bat

# 重启 watchdog
restart_watchdog.bat
```

## 队列文件格式

```json
{
  "state": "pending|running|idle",
  "cmd_id": "唯一标识符",
  "command": "要执行的命令",
  "type": "cmd|powershell",
  "timeout": 30
}
```

## result 文件格式

结果写入 `r_{cmd_id}.json`，格式：
```json
{
  "state": "done|error",
  "cmd_id": "对应 cmd_id",
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "error": "错误信息（如有）",
  "duration_ms": 1234,
  "timestamp": "2026-05-28 17:33:13.857"
}
```

## 自学习规则引擎（v11 新特性）

Claude Bridge v11 引入了**自学习机制**，能够从错误中自动积累规则，越用越智能。

### 规则引擎工作流程

```
命令发送前
    │
    ├── Apply-Rules() ← 加载 bridge_rules.json
    │      │
    │      ├── [cmd-escape-ampersand]     && → ^&^&  (cmd 模式)
    │      ├── [ps-wsl-semicolon]         "..." → '...' (powershell + WSL)
    │      ├── [ps-wsl-pipe]              "..." → '...' (保护管道符)
    │      └── [更多规则...]              自动累积
    │
    ▼
命令执行 → 正常 → 返回结果
    │
    └── 异常 → Log-Error() → error_history.json
                              │
                              ▼
                        Claude 分析模式
                              │
                              ▼
                        生成新规则
                              │
                              ▼
                        bridge_rules.json 更新
                              │
                              ▼
                  下次自动应用，不再犯错
```

### 已积累的规则

| 规则 ID | 触发条件 | 自动修复 |
|---------|---------|---------|
| `cmd-escape-ampersand` | cmd 模式 + `&&` 符号 | 自动替换为 `^&^&` |
| `ps-wsl-semicolon` | PowerShell + WSL + `;` | 自动将双引号换为单引号 |
| `ps-wsl-pipe` | PowerShell + WSL + `\|` | 自动保护管道符 |
| `cmd-wsl-nested-quotes` | cmd + WSL 嵌套引号 | 建议改用 powershell 类型 |

### 如何扩展规则

当遇到新类型的错误时，Claude 会：
1. 检测错误模式（退出码、stderr 内容、输出异常）
2. 在 `error_history.json` 中记录
3. 分析根因，生成新规则
4. 写入 `bridge_rules.json`
5. 下次同类问题自动修复

你也可以手动添加规则：
```json
{
  "id": "my-custom-rule",
  "description": "规则说明",
  "triggers": {
    "type": "cmd|powershell|any",
    "command_contains": "关键词",
    "pattern_in_command": "正则模式"
  },
  "fix": {
    "action": "escape|wrap_single_quotes|use_powershell_type|manual",
    "find": "要替换的文本",
    "replace_with": "替换为"
  }
}
```

## 重要须知

1. **type** — `"cmd"` 用 cmd.exe 执行，`"powershell"` 用 PowerShell 执行。
2. **WSL 推荐** — 用 `type:"powershell"` + 单引号包裹 bash 参数。
3. **cmd_id 必须唯一** — watcher 会跳过重复的 cmd_id。
4. **超时默认 30s**，可通过 `timeout` 字段覆盖。
5. **& 字符** 在 cmd.exe 中是命令分隔符，需要转义为 `^&`（规则引擎会自动处理）。
6. **规则引擎** 每 10 个命令重新加载一次 `bridge_rules.json`，支持动态更新。

## 版本历史

| 组件 | 版本 | 说明 |
|------|------|------|
| watcher | v11 | 自学习规则引擎 + 错误收集 + PID 锁 |
| watchdog | v3 | Heartbeat 检测、挂起恢复、双重检测 |
| bridge_rules | v1 | 规则引擎，支持自动修复和扩展 |
| error_history | v1 | 错误历史记录，支持模式分析 |
