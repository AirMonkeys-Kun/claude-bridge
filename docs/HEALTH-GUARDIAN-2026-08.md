# 2026-08-19/20 桥健康加固与守护层（排障记录 + 变更说明）

> 时间：2026-08-19 23:50 ~ 2026-08-20 10:56
> 范围：TCP 黑洞 / worker 假活 / watcher 假活 / agent 执行卡死 全面排障 + 6 项加固 + supervisor 守护层
> 状态：核心可用（TCP 命令 180-900ms 响应），遗留见文末

---

## 一、症状（用户可感知）

1. **TCP 19850 命令黑洞**：命令进去 10-60s 无响应，沙箱/桌面端一直卡。
2. **worker 假活**：worker 进程活着（心跳正常）但 named pipe 不在监听（`CallNamedPipe` 报 ERROR 3 找不到路径）。
3. **watcher 假活**：心跳一直更新（POOLSYNC/MEMORY 循环）但 queue 消费停摆。
4. **agent execute_command 卡死**：`active_connections` 累积不释放，客户端断开也释放不了。
5. **多实例累积**：4 个 bridge_agent 同时绑定 19850/19851（watchdog 反复拉起 + 旧实例不清）。

## 二、根因（按证据链）

| # | 根因 | 证据 |
|---|---|---|
| 1 | **内存硬约束**：系统 free 1-4GB（6-12%），worker 池（每 worker ~85MB powershell）建一个灭一个 | worker 14/14 ALIVE → 20 秒全灭；7 个 → 30 秒全灭；pool-sync prune 记录 |
| 2 | **agent queue-fallback 自环死锁**：agent 找不到 worker → 写 queue.txt → watcher 读 → TcpProxyBridge 转发回 agent TCP → agent 又找不到 worker → 又写 queue —— 无限递归 + `queue_serial` 线程锁互相等待 | active_connections 堆积不释放；watcher 日志无消费记录 |
| 3 | **worker pipe runspace 起不来**（历史遗留，8/17 后）：NamedPipeServerStream 未注册，且原健康检查只处理 `Completed/Failed` 状态，`NotStarted` 卡死永不重建 | pipe 列表可见僵尸实例但不可连 |
| 4 | **watcher TcpProxyBridge 无超时**：agent 黑洞时 `Connect()`/`ReadLine()` 无限阻塞 → watcher 主循环（含心跳+消费）全部停摆 = 假活 | watcher.log 只剩 POOLSYNC/MEMORY，queue 命令无人处理 |
| 5 | **watchdog 复活与外部管理打架**：被杀 agent 的 watchdog 在 parent 死后自动拉起新 agent → 多实例 → 抢端口 → 互相干扰 | 反复出现"回收多余 agent"后又有新实例 |

## 三、修复（6 项代码加固 + 守护层）

1. **worker_factory.ps1 内存护栏（V2.3）**
   - `Get-FreeMemGB` + `Get-AdaptivePlan`：<1GB fail-fast；1-2GB 建 2 个；2-3GB 建 3 个；3-5GB 建 7 个；≥5GB 全量 14。
   - 单类型创建同样截断到护栏允许数。
   - ⚠️ 含中文/箭头 → **必须 UTF-8 BOM**（PowerShell 5.1 无 BOM 读 UTF-8 中文会乱码报解析错误）。

2. **worker_generic.ps1 pipe 自愈（V3.5.1）+ ping 支持**
   - 健康检查触发条件：`Completed/Failed`（原）+ `Stopped` + `NotStarted` 卡死 >15s + **pipe 硬探测不存在**（`[System.IO.Directory]::GetFiles("\\.\pipe\")`）。
   - 重建冷却 5s；连续 3 次失败 → `pipeDegraded`（降级文件模式，worker 保持存活）。
   - **整段 try/except 保主循环**（V3.5 初版 recreating 异常会崩主循环 = 心跳停 = 比原来更糟；V3.5.1 修复）。
   - pipe 端支持 `type=ping`（health 探测用，不执行真实命令）。

3. **bridge_agent.py health 真实探测 + 启动内存检查**
   - `probe_worker_pipe()`：用 `CallNamedPipe` 发 ping，**不再只看 PID**（PID 活 ≠ pipe 通）。
   - health 新增 `workers_pipe_alive` / `workers_pipe_degraded` 字段（假活可被观测）。
   - `free_mem_gb()`（ctypes `GlobalMemoryStatusEx`）：启动时打印可用内存，<1GB 警告。

4. **watcher execution.ps1 TcpProxyBridge 有界超时**
   - `ConnectAsync().Wait(2000)` + `ReadLineAsync().Wait(3000)`：agent 黑洞时 watcher **最多卡 3s** 就降级 subprocess，主循环不再停摆。

5. **dispatch.py execute_command fallback → 本地 subprocess（核心修复，解自环）**
   - 原 queue fallback（写 queue.txt → watcher → TcpProxyBridge 回 agent）在 agent 也跑在宿主机时形成**自环死锁**。
   - 改为：worker 池不可用时 **agent 直接本地 `subprocess.run`** 执行（`shell=True`，带 timeout）。agent 在宿主，自给自足，不依赖 watcher。
   - 效果：TCP 命令 200-900ms 稳定返回（`channel=local_subprocess`）。

6. **bridge_agent_watchdog.py：supervisor 存活时不再复活**
   - `is_supervisor_active()`：`.supervisor_heartbeat` 新鲜（<60s）→ `launch_bridge_agent()` / `launch_restarter()` 直接跳过，复活职责交给 supervisor。
   - watchdog 降级为"supervisor 死后的兜底"。

7. **bridge_supervisor.py 守护层（新增，V1.0）**
   - 每 15s 巡检（功能判定，不止 PID）：watcher 心跳 <30s / agent health HTTP+19850 监听 / worker pipe 真实 ping。
   - 死了自动接管；孤儿/多余实例回收（**连带杀 watchdog 断复活源**）。
   - 手动关闭开关：`watcher/.manual_stop` 存在 → supervisor 退出托管。
   - 防风暴：60s 内拉起 >3 次 → backoff 5min；worker 池连续 3 次重建失败 → backoff 15min。
   - worker 池重建用**异步 Popen**（worker_factory 要 10-90s，阻塞会冻结巡检）。
   - **单实例锁 = Windows 命名 Mutex**（`Global\ClaudeBridgeSupervisor_V1`，内核级，进程死自动释放）。
   - 启动：`start_supervisor.bat`；日志 `bridge_supervisor.log`；心跳 `watcher/.supervisor_heartbeat`。

## 四、踩坑记录（避免重犯）

- **`newest()` 必须 `min(proc_age)`**：用 `max` 会保留最老的卡死实例 → agent 抖动循环。
- **单实例锁必须内核 Mutex**：PID 文件/心跳 mtime 有竞争窗口，实测 3 个 supervisor 并存互杀。
- **agent 启动要 60s 宽限期**：否则"刚拉起就判死"造成重启循环。
- **"杀所有 python"会误杀 server.py / unified.bot / resonova**：清理必须按 CommandLine 精确匹配。
- **health 200 / 进程存活 ≠ 功能正常**：worker/watcher 的"假活"骗得过 PID 检查，必须功能探测。
- **PowerShell 5.1 读 UTF-8 无 BOM 中文脚本会乱码报错**：改含中文的 .ps1 必须带 BOM。

## 五、遗留问题（下一轮）

1. **agent 周期性重启**：单 agent + 功能正常时 supervisor 仍偶发判"不健康"→ 重启（疑似多 agent 抢 19851 的残留干扰；watchdog 复活已修，待长观察确认）。
2. **worker pipe 在低内存（<3GB）下仍不稳**：runspace 起不来是历史问题；内存宽裕时（~3.2GB）实测 pipe 通道恢复（`channel=pipe`）。
3. **worker 池反复重建浪费内存**：backoff 已兜底（15min），根治需修 worker pipe runspace 或降低 worker 内存占用。

## 六、变更文件清单

修改：`bridge_agent.py`、`bridge_agent/dispatch.py`、`bridge_agent_watchdog.py`、`cluster/worker_factory.ps1`、`cluster/worker_generic.ps1`、`watcher/handlers/execution.ps1`
新增：`bridge_supervisor.py`、`start_supervisor.bat`
