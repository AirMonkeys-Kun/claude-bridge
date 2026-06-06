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
