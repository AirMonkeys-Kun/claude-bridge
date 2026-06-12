# Pool-Sync 修复总结

## 修复的两个 Bug（commit 20cf161）

### Bug 1: PSCustomObject → Hashtable 转换失败
- **症状**: `@{} + $w` 在 PS 5.1 中抛出 "Only hashtables can be added to hashtables"
- **根因**: `Read-Json`（别名 `Read-SafeJson`）使用 `ConvertFrom-Json` 返回 `PSCustomObject`，无法用 `+` 运算符合并到哈希表
- **修复**: 添加 `_ConvertTo-Hashtable` 辅助函数：
  ```powershell
  function _ConvertTo-Hashtable {
      param($InputObject)
      $h = @{}
      if (-not $InputObject) { return $h }
      $InputObject.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
      return $h
  }
  ```
- **影响**: 自 V2.4 以来（2026-06-10 起），`Sync-WorkerPool` **从未成功更新过 pool 文件**。Pool 仅由 `worker_factory.ps1` 初始创建时写入一次

### Bug 2: `last_heartbeat` 永不持久化
- **症状**: 即使 `@{} + $w` 没问题，早期返回 `if (-not $pidDelta) { return }` 也会跳过写入
- **根因**: 所有 worker PID 自 6 月 10 日以来未变化，`$pidDelta` 始终为 `$false`
- **修复**: 添加心跳变化检测，当 `last_heartbeat` 字段发生变化时设置 `$pidDelta = $true`

## 当前状态（2026-06-12 11:33）
- Watcher PID 29452（第三次重启后）
- 15 workers 全部存活，全部带有 `last_heartbeat` 时间戳
- Pool `updated` 时间刷新
- V3.1 代码活跃：dispatch retry、guardian 内存监控、pool 心跳持久化

## 未解决问题

### 通用 worker Named Pipe 全部超时
- 所有 6 个 generic worker 的 Named Pipe 均无法连接（`Connect(300)` 超时）
- Subprocess fallback 正常工作（72-99ms）
- 根因不明：可能是内存压力导致分页、管道监听线程异常、或 2 天运行后的管道状态积累
- 现有 workaround：subprocess fallback 完美工作

### `bridge_client.py --fallback` 参数顺序（已修复）
- 旧代码：`args[0].startswith("{")` 检查第一个参数，如果 `--fallback` 在前则 JSON 不会被解析
- 修复：过滤掉 `--` 开头的 flag 后再检查 JSON 参数
- 现在 `--fallback '{"command":"..."}'` 和 `'{"command":"..."}' --fallback` 都可以工作

## 近期 Git 提交历史
- `20cf161` — pool-sync fix: PSCustomObject → hashtable + last_heartbeat 持久化
- `a23444c` — V3.1: dispatch retry + pool heartbeat + guardian 内存 + worker 缩减
- `347177b` — logging: 3-level fallback + rotation fix
- `242e4fb` — dispatch WSL timeout fix
