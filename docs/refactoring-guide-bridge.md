# 通信桥重构指南（给另一对话的提示）

## 当前架构问题

通信桥代码（PowerShell）有以下核心问题需要重构：

### 1. 代码重复（最严重）
以下工具函数被复制粘贴到 5 个文件中，应提取为共享 `.psm1` 模块：
- **Write-SafeFile**（重试写入）— watcher.ps1, worker_template.ps1, guardian_v3.ps1, worker_generic.ps1, worker.ps1
- **Read-SafeJson**（重试读取+JSON解析）— 同上 5 个文件
- **Write-Log**（时间戳日志）— 同上 5 个文件
- **UTF8NoBOM 编码初始化** — 每个文件都有
- **PID 锁/心跳写入** — 4 个文件重复
- **子进程执行逻辑**（ScriptBlock快路径 + 进程启动 + 超时 + 进度刷新）— 4+ 个文件重复
- **ScriptBlock 快路径执行** — 5 处重复

建议创建 `BridgeCommon.psm1` 包含以上所有共享函数。

### 2. 两套 Worker 系统并存
- **V21 typed workers**：`worker_generic.ps1`（通过 worker_factory.ps1 创建），命名管道派发
- **Legacy _bridge workers**：`file_bridge/worker.ps1`、`wsl_bridge/worker.ps1`、`system_bridge/worker.ps1` 等，基于队列文件+EventWaitHandle

两套都在 register-workers.ps1 注册，消耗资源。应只保留一套。

### 3. 主循环 383 行（watcher.ps1 L536-919）
一个 try/catch 包含 10+ 种职责。应拆为独立函数：
- Watch-Queue（队列监听）
- Invoke-Command（命令派发/执行）
- Write-CommandResult（结果写入）
- Check-SelfUpgrade（自升级检测）
- Invoke-Housekeeping（清理/心跳）
- Test-Inflight（飞行中结果检查）

### 4. queue.txt 无文件锁
依赖 WriteAllText + 重试循环，存在竞争条件。建议用 `[System.IO.FileStream]` + `FileShare.None` 或 Mutex。

### 5. 结果字段命名不一致
- watcher 输出：`exit_code`, `stdout`, `stderr`
- _bridge/worker.ps1 输出：同时写 `exit_code` 和 `e`、`stdout` 和 `o`
- worker_generic 输出：`exit_code`, `fast_path`, `pipe_direct`

应统一为一种格式。

### 6. 硬编码路径
- `register-workers.ps1:38` — fallback 路径缺少 `tools\`（`D:\zebbingo\claude-bridge` 应为 `D:\zebbingo\tools\claude-bridge`）
- `guardian_v3.ps1:495` — 端口 4000 硬编码
- `watcher.ps1:359` — 事件路径硬编码

### 7. Guardian 函数名拼写错误
`Invoke-RespwanDeadWorkers`（L385）应为 `Invoke-RespawnDeadWorkers`

### 8. 命名规范全面违反
PowerShell 最佳实践要求函数用 `Verb-Noun` 格式。当前大量使用：
- `TLog`, `WriteF`, `ReadJ`, `WF`, `RJ`（应为 `Write-Log`, `Write-SafeFile`, `Read-SafeJson`）
- `ExecCmd`（应为 `Invoke-CommandExecution`）

## 建议的模块结构

```
claude-bridge/
  modules/
    BridgeCommon.psm1     # 文件读写、日志、UTF8、PID锁、心跳
    BridgeExecution.psm1  # ScriptBlock快路径、子进程执行、进度刷新
    BridgeQueue.psm1      # 队列文件管理、状态转换
    BridgePool.psm1       # Worker池加载、查询、轮询
    BridgeIpc.psm1        # 命名管道客户端/服务端
  watcher/
    watcher.ps1           # 精简主循环（调用模块函数）
  cluster/
    worker_generic.ps1    # 唯一的 worker（其他类型通过参数区分）
```

## 代理桥已完成

代理桥（server.py, 1970行）已完全模块化拆分为 `proxy/app/` 包：
- `errors.py` — 异常类型
- `sse.py` — SSE 辅助
- `circuit_breaker.py` — 熔断器
- `rate_limiter.py` — 限流器
- `utils.py` — 工具函数
- `routing.py` — 路由
- `config.py` — 配置+ProxyState（替代26+全局变量）
- `metrics.py` — 指标+审计
- `dedup.py` — 去重
- `providers/client.py` — HTTP客户端+重试
- `providers/anthropic.py` — Anthropic透传
- `providers/openai.py` — OpenAI转换
- `main.py` — 薄协调层

新入口：`python run_v2.py`（旧 `server.py` 保留为备份）

## 通信桥 V22 重构已完成 (2026-06-06)

watcher.ps1 主循环已从 383 行内联代码重构为 9 个命名处理函数 + 模块引用。

### 已完成的改动

**1. 共享模块 (modules/)**
- `BridgeCommon.psm1` — 13 个导出函数：Write-SafeFile, Read-SafeJson, Read-SafeText, Write-BridgeLog, Write-Heartbeat, Test-HeartbeatAlive, Enter-PidLock, Get-LockedPid, Reset-QueueToIdle, Get-IdleQueueJson, New-CommandResult, Write-CommandResult, Invoke-LogRotation
- `BridgeExecution.psm1` — 4 个导出函数：Resolve-CommandType, Invoke-ScriptBlockFastPath, Invoke-Subprocess, Invoke-BridgeCommand

**2. watcher.ps1 V22 重构**
- 内联 Write-Text/Read-Json/Log 替换为模块导入 + 别名/包装
- 主循环从 383 行缩减到 ~35 行，调用 9 个提取的命名函数：
  - `Invoke-Housekeeping` — 周期清理（hostLoopMode + guardian）
  - `Invoke-PollInflight` — 检查异步派发结果
  - `Invoke-HandleDedup` — 内容哈希去重
  - `Invoke-ApplyRules` — 规则引擎转换
  - `Invoke-MetaCommand` — __BRIDGE_RESTART__/__BRIDGE_STOP__
  - `Invoke-InlineExecution` — __INLINE__ 类型执行
  - `Invoke-UserContextExecution` — user 类型路由
  - `Invoke-InprocessFallback` — 进程内执行（ScriptBlock + 子进程）
  - `Test-SelfUpgrade` — 自升级检测
- 结果构建使用 `New-CommandResult` + `Write-CommandResult`
- 队列重置使用 `Reset-QueueToIdle`

**3. Git 状态**
- commit `8179e5e` 已推送到 main
- watcher V22 已部署并运行（通过 3 种路径验证：powershell dispatch, inline, cmd）

### 仍需改进的问题（给下一轮）

1. **queue.txt 文件锁** — 仍依赖 WriteAllText + 重试，存在竞争条件（多对话同时写）
2. **两套 Worker 系统** — V21 typed workers + legacy _bridge workers 仍然并存
3. **结果字段命名** — `_bridge/worker.ps1` 仍写 `e`/`o`/`s` 字段
4. **BridgeExecution.psm1 未在 watcher 中完全使用** — Invoke-InprocessFallback 保留了原有 ScriptBlock+subprocess 代码（比模块的 Invoke-BridgeCommand 更激进，fast-path 对所有 powershell 类型生效），可后续统一
5. **worker_generic.ps1 / worker_template.ps1** — 仍未引用共享模块，仍有重复代码
6. **Legacy-ApplyRules** — 可以提取到独立的规则模块
7. **Log-Error** — 可以提取到独立的学习模块
