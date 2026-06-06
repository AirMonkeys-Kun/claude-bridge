# Phase 4 架构指令 — 从"能用"到"满意"

> 日期：2026-06-06 | 顶层视角产出
> 前提文档：ARCHITECTURE.md（全貌）、EVOLUTION.md（历史）、9p-cache-handbook.md、powershell-best-practices.md
>
> 本文件是 Phase 4 指令，定义进入"满意"状态的标准和路径。

---

## 第一性原理：什么叫"满意"

以下是从所有历史对话中提炼的用户质量标准。每条都有对话出处。

### 标准 1：模块边界清晰 — 每个文件一个职责

> "你还欠缺了看文档 考虑当初他为何要这样设计的目的 我们需要不破坏目的 又能更上一层楼"

**具体定义**：
- 每个文件 ≤ 300 行有效代码（不含注释空行）
- 超过 300 行的文件必须拆分，证明一个文件有多职责的证据是：函数不需要互相调用
- 不破坏原始设计意图——拆分只是物理分离，不是逻辑重写

### 标准 2：零过期假设

> "你还在用老的提示 这也是不对的 架构早已经改了"
> "之前的研究和洞察都应该加入 不然就等于我们白研究了"

**具体定义**：
- 不允许任何约定、记忆、文档、提示词和当前代码不一致
- 修改架构后必须立即更新所有依赖该知识的系统（记忆、提示词、参考文档）
- 知识必须从对话沉淀到持久化文档

### 标准 3：封闭递归 — 修复必须到根

> "你不断回归 然后我们就能发现问题 递归解决问题 不留隐患"

**具体定义**：
- 每次修复必须回答：这个 bug 的根因是什么？同一类 bug 还有没有其他地方存在？
- 修复后不能引入更多新问题（同类问题数量必须下降，不能上升）
- 每个修复都附带验证方式（手动的或自动的）

### 标准 4：架构驱动，非 bug 驱动

> "我们打算站在架构师 和顶级编程专家规范的角度重构稳定版 但是发现了一堆缺陷 然后进入了修复缺陷环节"

**具体定义**：
- 修 bug 不是项目目标，达到生产级架构才是目标
- 修 bug 是发现架构缺陷的信号，不是终点
- 每次修完 bug 必须问：这个 bug 暴露了架构的什么缺陷？要怎么改架构才能让这类 bug 不再出现？

### 标准 5：知识即代码

> 无直接引语，但"你已经看到了 我要求很高" 和每次要求写文档的行为

**具体定义**：
- 设计决策必须记录 WHY（为何这么做），而非只记录 WHAT（做了什么）
- 性能基准、问题发现、修复过程必须有文档可追溯
- 文档要精确到：引用可查、数据可验、结论可复现

---

## 当前不合标准项

对照上述标准，当前代码和架构的差距：

| 标准 | 当前状态 | 差距 |
|------|---------|------|
| **模块边界清晰** | watcher.ps1 920 行单体。bridge_agent.py 270 行但无模块化。7 个 worker 重复代码。 | ❌ 不达标 |
| **零过期假设** | 记忆文件已清理。但提示词系统（memory）中的 bash-disabled 仍可能被旧会话加载。 | ⚠️ 部分达标 |
| **封闭递归** | 今天修复了 V22 regression，但同类问题（handler 只在一半路径执行）可能还有其他。 | ⚠️ 部分达标 |
| **架构驱动** | 三个 gap 修复是 bug 驱动的，不是架构驱动的。 | ❌ 未达标 |
| **知识即代码** | 架构白皮书已创建、9P 研究已文档化、演进史已有。 | ✅ 达标 |

**唯一有意义的下一步**：把 watcher.ps1 拆出模块。这是架构驱动、非 bug 驱动、最能提升质量的改动。

---

## Phase 4 执行路线

### Step 1：watcher.ps1 模块拆分（最高优先）

不改逻辑，只拆文件。920 行 → 6 个 handler 文件 + 3 个 lib 文件 + 1 个主循环。

```
watcher/watcher.ps1              # 主循环 ~80 行（只调度 handler）
watcher/handlers/housekeeping.ps1
watcher/handlers/dedup.ps1
watcher/handlers/rules.ps1
watcher/handlers/meta-command.ps1
watcher/handlers/execution.ps1
watcher/handlers/self-upgrade.ps1
watcher/lib/logging.ps1
watcher/lib/bridge-common.ps1
watcher/lib/config.ps1
```

**增量兼容**：`watcher.ps1` 用 `. $PSScriptRoot/handlers/housekeeping.ps1` dot-source 加载所有 handler，原有入口不变。不要修改现有函数名。

**验证方式**：拆分后 watcher 正常启动、命令正常执行、heartbeat 正常更新。

### Step 2：bridge_agent.py 韧性重构

| 当前 | 目标 |
|------|------|
| watchdog 是 daemon 线程 | watchdog 是独立子进程（Python 进程对） |
| 无信号处理 | SIGTERM/SIGINT graceful shutdown |
| 单线程 accept | 可配置线程池 |
| 无健康端点 | 添加 /health HTTP 端点 |
| 无连接 backoff | 指数退避重试 |

### Step 3：Worker 统一模板

用一个模板生成所有 7 个 worker，消除重复代码：

```
cluster/worker-template.ps1       # 模板（只一份逻辑）
cluster/worker-config.json        # 类型差异：管道名、类型名、权限
cluster/worker_factory.ps1        # 模板 + 配置 → 生成 7 个 worker
```

### Step 4：集成测试套件

```
test/
├── test_all.ps1                   # 一键运行全部
├── fixtures/                      # 测试用命令和期望结果
└── cases/
    ├── basic                      # echo, pwd, dir
    ├── concurrent                 # 并发命令
    ├── self-heal                  # 杀 worker → 自动恢复
    ├── 9p-cache                   # 读缓存穿透验证
    ├── tcp-bridge                 # Phase 3 路径
    └── upgrade                    # 自升级
```

### 不做的事项（明确排除）

- 不改 PowerShell 5 → 7 | PS5 是 Windows 内置，S4U 环境下已验证稳定
- 不做日志聚合 | 日志量不大，中心化收益低
- 不替换 queue.txt | 作为 TCP 的回退路径有意义，不需要删除
- 不做 GUI 管理面板 | 不需要

---

## "Done" 的定义

当以下条件全部满足时，通信桥达到"满意"状态：

- [ ] watcher 主文件 ≤ 100 行，所有 handler 在独立文件中，每个文件 ≤ 300 行
- [ ] bridge_agent 有 watchdog 子进程、信号处理、/health 端点
- [ ] 所有 worker 由一个模板生成，逻辑一致
- [ ] 集成测试套件存在，能一键运行全部测试、验证关键路径
- [ ] 本文档中所有标准（模块边界、零过期、封闭递归、架构驱动、知识即代码）有具体证据证明已符合
- [ ] 没有"下次再修"的积压—要么修了要么明确决定不修

---

## 参考

- `docs/ARCHITECTURE.md` — 当前架构全貌
- `docs/EVOLUTION.md` — 完整演进史
- `docs/9p-cache-handbook.md` — 9P 缓存研究
- `docs/TCP-MIGRATION-PLAN.md` — Phase 3 迁移方案（已完成）
- `docs/powershell-best-practices.md` — PS5 注意事项
- `docs/PHASE3-DIRECTIVE.md` — Phase 3 实现指令（已执行完毕）
