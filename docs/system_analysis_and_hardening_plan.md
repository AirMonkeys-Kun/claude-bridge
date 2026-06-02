# Claude Bridge System Analysis & Hardening Plan
## 2026-06-01 | 基于错误历史与系统状态

---

## 一、系统概览

### 当前架构
```
claude-bridge/
├── watcher/        ← 主桥接进程 (watcher.ps1 v12)
│   ├── bridge_rules.json     ← 规则引擎配置 (3条活跃规则)
│   ├── error_history.json    ← 错误历史 (111条记录)
│   ├── fix_*.py × 7          ← ⚠️ 7个重叠的修复脚本
│   └── r_*.json × 4          ← ⚠️ 残留的临时结果文件
├── cluster/        ← 集群调度器 (V5 rule_engine.ps1)
│   ├── *_bridge/   ← 6个worker bridge
│   ├── scheduler.ps1
│   └── launch_workers.bat
└── fix_*.ps1       ← 根目录下多个热修复脚本
```

### 数据结构
- **session JSON**: `C:\Users\Administrator\AppData\Local\Claude-3p\local-agent-mode-sessions\`
- **scheduled tasks**: `D:\Backup\Documents\Claude\Scheduled\`
- **workspace**: `D:\zebbingo\` (主仓库)

---

## 二、错误分析 (111条记录)

### 2.1 错误分类

| 错误类型 | 数量 | 占比 | 严重度 | 根因 |
|---------|------|------|--------|------|
| PowerShell CLIXML stderr 噪音 | ~35 | 31% | 低 | PS 将非错误信息写入 stderr |
| TI 权限提升失败 | ~15 | 14% | 高 | 系统安全策略阻止 |
| 命令退出码非零 (实际错误) | ~20 | 18% | 中 | 路径错误/编码问题/语法错误 |
| cmd 引号转义 (&&/\|) | ~5 | 4% | 中 | cmd.exe 特殊字符解析 |
| 空输出 (零退出码但无返回) | ~15 | 14% | 低 | 命令正确执行但无匹配结果 |
| WSL 跨 shell 问题 | ~3 | 3% | 中 | PowerShell 解析 WSL 分号 |
| 进程/Task Scheduler 问题 | ~10 | 9% | 低 | PID 不存在/任务已删除 |
| Python 编码错误 (GBK) | ~5 | 4% | 中 | Windows 终端 GBK 编码 |
| 文件未找到 | ~3 | 3% | 低 | 路径引用过时 |

### 2.2 关键风险点

**高风险 - 立即处理:**
1. **TI 权限提升 15+ 次尝试全部失败** — `ti_forge.cs` 编译和运行持续失败，这是高权限操作，不应在无人值守场景下使用。
2. **42.9% 命令错误率** — 统计自最近 7 条命令。虽然样本小，但趋势不好。

**中风险 - 本轮处理:**
3. **规则引擎只有 3 条规则** — 仅 `cmd-escape-ampersand` 有 hit。CLIXML 过滤规则未自动生成 (阈值 10 次，已达 35 次但可能因其他条件未触发)。
4. **`fix-wsl-paths` 每 5 分钟运行一次** — 但 WSL 路径早已清理干净。
5. **7 个重叠的 fix 脚本** — 功能重复。

**低风险 - 后续优化:**
6. **watcher 不稳定** — 1 小时内重启 5 次
7. **路径混乱** — `C:\Users\wsx` vs `C:\Users\Administrator`

---

## 三、加固措施

### Phase 1: 清理

#### 3.1 禁用冗余定时任务
```
fix-wsl-paths: ENABLED → DISABLED
WSL路径已全部清除，每5分钟运行无意义
```

#### 3.2 归档重叠脚本
保留: `fix_sessions_current.py`
归档: `fix_wsl.py, fix_wsl2.py, fix_all_sessions.py, fix_direct.py, fix_scheduled_tasks.py, fix_wsl_onefile.py`

#### 3.3 清理临时文件
删除 `watcher/r_*.json`

### Phase 2: 加固

#### 3.4 添加缺少的规则到 bridge_rules.json
```
规则1: clixml-stderr-filter → 过滤 PowerShell CLIXML stderr
规则2: python-utf8-encoding → Python 自动加 PYTHONIOENCODING=utf-8
规则3: path-wsx-to-admin → 自动替换 C:\Users\wsx → C:\Users\Administrator
规则4: cmd-pipe-escape → cmd 模式下 | 转义
```

#### 3.5 创建统一系统健康检查脚本

#### 3.6 隔离 TI 权限提升脚本

### Phase 3: 升级

#### 3.7 watcher 稳定性增强

#### 3.8 统一路径引用

---

## 四、执行检查清单

- [ ] Phase 1: 禁用 fix-wsl-paths 定时任务
- [ ] Phase 1: 删除已完成的一次性任务 fix-wsl-paths-now
- [ ] Phase 1: 归档 6 个重叠 fix 脚本
- [ ] Phase 1: 清理 4 个临时结果文件
- [ ] Phase 2: 添加 4 条新规则到 bridge_rules.json
- [ ] Phase 2: 创建统一健康检查脚本
- [ ] Phase 2: 隔离危险 TI 脚本
- [ ] Phase 3: 路径统一 (wsx → Administrator)

---

## 五、验证方法

执行健康检查后应满足:
1. `fix-wsl-paths` 任务状态: DISABLED
2. `error_history.json` 最近记录错误率 < 30%
3. WSL 路径全局搜索: 0 条结果
4. `bridge_rules.json` 规则数: ≥ 7 条
5. watcher/ 目录下 fix 脚本数: 1 个
6. TI 脚本: 已从 watcher/ 移除
