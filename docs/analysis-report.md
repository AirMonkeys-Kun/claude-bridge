# Claude Bridge 深度分析报告

> 生成日期: 2026-06-03
> 扫描范围: 234 个 r_*.json 结果文件, 所有 bridge 的 worker.log, watcher.log, 规则引擎数据
> 分析方式: Python 脚本全量解析 + 逐文件根因分类
>
> **P0 优化完成时间: 2026-06-03**
> 见第 8 节 — 3 项 P0 优化已全部实施

---

## 1. 架构全景

### 两套独立的调度系统

```
外部请求 → watcher/queue.txt → 主 Watcher (SYSTEM 进程内执行)
                                   │
                                   ├── type=user → user_bridge (用户上下文)
                                   │
                                   └── 其他类型 → 直接在当前进程执行

cluster/master_queue.txt (永远空闲，从未被写入)
        │
master_scheduler.ps1 (永远空闲，0 次调度)
        │
   ┌────┼────┬────┬────┬────┐
 network registry wsl file process system
 (0结果) (0结果) (0结果) (4结果) (39结果) (1结果)
```

**关键事实：** 6 个 cluster bridge 背后的 `master_scheduler.ps1` 从创建至今从未接收过一条命令。`master_queue.txt` 从未被写入。这些 worker 进程的日志里只有启动信息，没有任何执行记录。

### 实际活跃的组件

| 组件 | 角色 | 状态 | 处理命令数 |
|------|------|------|-----------|
| `watcher/watcher.ps1` | 主调度+执行器 | **活跃** | 141 |
| `cluster/user_bridge/worker.ps1` | 用户上下文执行器 | **活跃** | 49 |
| `cluster/process_bridge/worker.ps1` | 进程操作 | **部分活跃** | 39 |
| `cluster/file_bridge/worker.ps1` | 文件操作 | **几乎闲置** | 4 |
| `cluster/system_bridge/worker.ps1` | 系统操作 | **几乎闲置** | 1 |
| `cluster/network_bridge/worker.ps1` | 网络操作 | **闲置** | 0 |
| `cluster/registry_bridge/worker.ps1` | 注册表操作 | **闲置** | 0 |
| `cluster/wsl_bridge/worker.ps1` | WSL 操作 | **闲置** | 0 |

### WSL Bridge 特殊问题

`wsl_bridge/worker.ps1` 是一个 V4 增强版 worker（13KB，含 Named Pipe 服务器、后台文件监视器、V4 inline 执行优化），但 `runner.ps1` 调用的是 `worker_template.ps1` 通用模板。这个定制 worker 完全是死代码。

---

## 2. 命令执行统计

### 总体数据

| 指标 | 数值 |
|------|------|
| 总命令数 | 234 |
| 成功 (exit=0) | 203 (86.75%) |
| 失败 (exit=1) | 15 (6.41%) |
| 异常 (exit=-1) | 16 (6.84%) |
| 总墙钟时间 | 1,203,439 ms (20.1 分钟) |

### 执行时间分布

| 指标 | 数值 |
|------|------|
| 平均耗时 | 5,143 ms |
| 中位数 | 495 ms |
| 最小值 | 1 ms |
| 最大值 | 219,464 ms (3.6 分钟) |
| P95 | 30,209 ms |
| P99 | 85,110 ms |

### 命令类型分布

| 类型 | 数量 |
|------|------|
| powershell | 137 (58.5%) |
| cmd | 75 (32.1%) |
| inline | 16 (6.8%) |
| wsl | 1 (0.4%) |
| 未知/其他 | 5 (2.1%) |

### 各 Bridge 执行详情

| Bridge | 文件数 | 平均耗时 | 中位数 | P95 | CLIXML 污染 |
|--------|--------|----------|--------|-----|------------|
| watcher | 141 | 3,580 ms | 523 ms | 30,000 ms | 0 |
| user_bridge | 49 | 13,064 ms | 114 ms | 74,428 ms | 0 |
| process_bridge | 39 | 1,172 ms | 182 ms | 6,299 ms | 14 (36%) |
| file_bridge | 4 | 3,161 ms | 1,949 ms | 7,756 ms | 4 (100%) |
| system_bridge | 1 | 153 ms | 153 ms | 153 ms | 0 |

---

## 3. 失败命令根因分析

### 31 条失败命令分类

| 类别 | 数量 | 严重程度 | 说明 |
|------|------|----------|------|
| PowerShell 语法 Bug | 6 | **高** | `$_` 在字符串中失效、`&&` 操作符、f-string 转义失败 |
| 超时设置太短 | 5 | **中** | `find_deepseek2` 30s→需 220s, `chk_worker_001` 15s→需 30s+ |
| 环境问题 | 5 | 低 | 文件被锁、路径不存在（瞬态） |
| CLIXML 假阳性 | 3 | 低 | 已通过 Filter-CLIXML 缓解 |
| 旧版 Unknown type: query | 2 | **已修复** | watcher v12 已加 fallback |
| 孤儿 running 状态 | 1 | 无害 | `dl_codex_003` 重启遗留 |

### PowerShell 语法 Bug 详情

这些是 inline 代码生成的质量问题，需要修复命令构造逻辑：

| 命令 | Bug | 影响 |
|------|-----|------|
| `check_keys` | `$env:$_` — `$_` 在字符串插值中无意义 | user_bridge + watcher 都失败 |
| `kill_proxy` | `catch { Write-Output "Failed...$_" }` — 同上 | process_bridge |
| `daily_report_v1` | `&&` 操作符在 PowerShell 中无效 | 多条命令 |
| `test_prefix_oa` | Python f-string `f"{'model':<35}"` 中 `:<35` 被 PS 截获 | user_bridge + watcher |
| `start_new_proxy` | `Start-Process` 在某些上下文中不可用 | user_bridge |

### 超时调优清单

| 命令 | 当前超时 | 实际耗时 | 建议超时 |
|------|----------|----------|----------|
| `find_deepseek2` | 30s | 219.5s | 240s 或移除 |
| `git_push_*` | 30s | 19-30s | 60s |
| `chk_worker_001` | 15s | 16.8s | 30s |
| `v4_grd_chk` | 10s | 13.3s | 20s |
| `claude_proc` | 30s | 35.2s (TIMEOUT) | 需要诊断原因而非加时间 |

---

## 4. 命令重复执行

**37 条命令同时在 watcher 和 user_bridge 各执行一次。** 这些命令在 user_bridge 中执行是因为当时认为它们需要用户上下文（git、环境变量），但后续验证发现 git 等操作通过 `git -C` 在 SYSTEM 上下文中完全可用——git 凭据通过 Windows Credential Manager 全局可访问。重复执行的根本原因是命令分发逻辑将同一命令同时路由到两个 worker。

### 最浪费的重复执行

| 命令 | 单次耗时 | 合计浪费 | 冗余比 |
|------|----------|----------|--------|
| `daily_report_v2` | ~85s | 85s | 100% |
| `daily_report_prod_v1` | ~59s | 59s | 100% |
| `daily_report_v3` | ~38s | 38s | 100% |
| `find_deepseek2` | 220s+35s | 35s (watcher 超时) | 部分 |
| `test_all` | ~20s | 20s | 100% |
| `git_push_cb_v1` | ~19s | 19s | 100% |
| **合计** | | **~221s (3.7 分钟)** | |

### 重复命令列表

```
daily_report_v2, daily_report_v3, daily_report_prod_v1
  → Python 报表生成, 每个都在两个 bridge 跑一次

test_all, test_ds, test_xiaomi
  → API 测试, 双重执行

git_push_cb_v1, git_push_company_v1, push_via_ps_v1
  → Git 推送, 双重执行

check_cfg, check_env, check_keys, check_saved
  → 环境检查, 双重执行

find_deepseek, find_deepseek2
  → 文件扫描, 双重执行

start_new_proxy, debug_proxy
  → 代理管理, 双重执行
```

---

## 5. 规则引擎运行效果

### 规则命中情况

| 规则 | 命中 | 自动生成 | 状态 |
|------|------|----------|------|
| `cmd-escape-ampersand` | 7 | 否 | 活跃 |
| `ps-wsl-semicolon` | 0 | 否 | 活跃 |
| `ps-wsl-pipe` | 0 | 否 | 活跃 |
| `cmd-wsl-nested-quotes` | 0 | 否 | 活跃 |
| `clixml-stderr-filter` | 18+ | 否 | 活跃 |
| `auto-cmd-escape-ampersand` | 0 (新) | 是 (置信度100%) | 活跃 |
| `rule-template` | 0 | - | 模板 |

### 自动规则生成

- `auto-cmd-escape-ampersand` 在 20.5% 命中率下自动生成（阈值 5%）
- 与手动规则 `cmd-escape-ampersand` 功能重复，但因 ID 不同未被去重
- `hasAmpersandRule` 检查已添加防止后续再生成重复规则

### 错误历史清洗结果

| 项目 | 清洗前 | 清洗后 | 减少 |
|------|--------|--------|------|
| 总条目 | 126 | 44 | 82 (65%) |
| CLIXML 噪声 | 50 | 0 | 50 |
| stderr_with_success_exit | 20 | 5 | 15 |
| exit_code_non_zero_clixml_only | 12 | 9 | 3 |

### 检测到的模式

| 模式 | 出现次数 | 风险 | 修复方案 |
|------|----------|------|----------|
| `ampersand_in_cmd` | 7 | 高 | cmd 模式下用 `^&^&` 转义 |
| `pipe_in_cmd` | 5 | 中 | cmd 模式管道注意转义 |

---

## 6. 优化建议汇总

### P0 — 高优先级（影响正确性）

| # | 优化项 | 说明 | 涉及文件 |
|---|--------|------|----------|
| 1 | **修复 6 个 PowerShell 语法 Bug** | `$_` 字符串插值、`&&` 操作符、f-string 转义 | 命令生成逻辑 |
| 2 | **消除命令重复执行** | watcher + user_bridge 各跑一份，加去重或改路由 | `watcher.ps1` |
| 3 | **超时参数调优** | 5 个命令的超时太短导致假失败 | `watcher.ps1` 或调用方 |

### P1 — 中优先级（架构清理）

| # | 优化项 | 说明 | 涉及文件 |
|---|--------|------|----------|
| 4 | **废弃或激活 Cluster Scheduler** | 6 个 bridge 闲置，调度架构未连通 | `master_scheduler.ps1`, 路由逻辑 |
| 5 | **激活 WSL Bridge 定制 worker** | `wsl_bridge/worker.ps1` V4 增强版未被使用 | `runner.ps1` |
| 6 | **清理路径迁移残留** | 旧路径 `C:\Users\wsx\Desktop\claude-bridge\` 的引用 | 多个命令 |

### P2 — 低优先级（观测/防御性）

| # | 优化项 | 说明 |
|---|--------|------|
| 7 | 自动规则去重增强 | `auto-cmd-escape-ampersand` 与 `cmd-escape-ampersand` 功能重复 |
| 8 | 孤儿 "running" 状态检测 | `dl_codex_003` 进度文件残留，可加自动清理 |
| 9 | CLIXML 过滤率监控 | 目前 18 条仍有 CLIXML，确认过滤是否达到 100% |

---

## 7. 数据来源

- `D:\zebbingo\tools\claude-bridge\watcher\` — 主 watcher + 结果文件
- `D:\zebbingo\tools\claude-bridge\cluster\*_bridge\` — 各 bridge worker
- `D:\zebbingo\tools\claude-bridge\watcher\error_history.json` — 错误历史
- `D:\zebbingo\tools\claude-bridge\watcher\bridge_rules.json` — 规则引擎
- `D:\zebbingo\tools\claude-bridge\watcher\watcher.log` — 主日志
- `D:\zebbingo\tools\claude-bridge\cluster\*_bridge\worker.log` — 各 worker 日志

---

## 8. P0 优化实施记录

### P0-1: 修复 6 个 PowerShell 语法 Bug

**修改文件:**
- `watcher/bridge_rules.json` — 新增 4 条规则 + 修复 1 条已有规则
- `cluster/rule_engine.ps1` — 新增 `pattern_regex` 触发器 + 增强模式检测 + 增强自动规则生成

**新增规则:**

| 规则 ID | 解决的问题 | 修复方式 | 对应 Bug |
|---------|-----------|----------|----------|
| `ps-double-ampersand-to-cmd` | `&&` 在 PowerShell 中无效 | 自动切换类型为 cmd | `daily_report_v1` |
| `ps-fstring-format-to-cmd` | Python f-string `:<N>` 被 PowerShell 拦截 | 自动切换类型为 cmd | `test_prefix_oa` |
| `ps-start-process-to-powershell` | `Start-Process` 在 cmd 中不存在 | 自动切换类型为 powershell | `start_new_proxy` |
| `ps-env-dollar-underscore` | `$env:$_` 无效变量语法 | 替换为 `${env:$_}` | `check_keys` |
| `ps-dollar-pid-colon-underscore` | `$pid: $_` 被解析为作用域变量 | 替换为 `$($pid): $_` | `kill_proxy` |

**引擎增强:**
- Apply-Rules: 新增 `pattern_regex` 触发器（原生正则匹配）
- Log-ExecutionError: 新增 6 种模式签名检测（`ps_ampersand`, `python_fstring_format`, `dollar_underscore_env` 等）
- Generate-Rules: 新增 3 种自动规则候选模式

### P0-2: 消除命令重复执行

**修改文件:**
- `watcher/watcher.ps1` — 新增结果缓存系统

**实现:**
- 命令结果缓存（最大 50 条，TTL 5 分钟）
- 本地执行 (`cmd`/`powershell`) 完成后自动写入缓存
- user_bridge 执行前检查缓存，命中则直接复用结果
- 预计消除 ~221s 的重复执行时间（daily_report 等 37 条重复命令）

### P0-3: 超时参数调优

**修改文件:**
- `watcher/watcher.ps1` — 新增命令模式匹配超时覆盖

**调整清单:**

| 命令模式 | 原超时 | 新超时 | 依据 |
|----------|--------|--------|------|
| `find_deepseek` / deepseek 扫描 | 30s | 240s | 成功执行需 220s |
| `git push` 系列 | 30s | 60s | 正常推送 ~19s |
| `chk_worker