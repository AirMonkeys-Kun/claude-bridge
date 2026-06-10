# MEMORY.md — Memory Index

> 自动维护 — 记录 Claude Bridge 系统的重要文档和上下文快照
> 最后更新: 2026-06-10 (Run #22 — self-evolve)

---

## 活跃文档

| # | 文件 | 类型 | 说明 |
|---|------|------|------|
| 1 | [dual-bridge-architecture](dual-bridge-architecture.md) | project | 双桥架构总览 — 代理桥 (localhost:4000, AI 推理) + 通信桥 (queue.txt, 宿主机操作) |
| 2 | [proxy-cowork-integration](proxy-cowork-integration.md) | project | claude-desktop-config proxy (localhost:4000) 与 Cowork desktop 的集成状态 — V13, adaptive thinking fix |
| 3 | [proxy-history-and-thinking-issues](proxy-history-and-thinking-issues.md) | project | Proxy 从 V6 到 V13 的演进历史，所有已修复问题 (streaming, thinking, SSE, JSON 序列化) |
| 4 | [proxy-vs-direct-self-observation](proxy-vs-direct-self-observation.md) | reference | Claude 自观察的代理模式 vs 直连模式差异 — 修复后状态对比数据 |

---

## 系统快照 (Run #22 — 2026-06-10 06:04 UTC)

| 组件 | 状态 | 详情 |
|------|------|------|
| Watcher | ✅ 运行中 | 心跳 06:04:21, 无 FATAL/ERROR |
| Watchdog | ✅ 运行中 | 心跳 06:04:20 |
| Worker pool | ✅ 16/16 | 6 types, 所有 PID 当前 |
| Bridge Agent | ✅ Phase 4 | PID 10888, pipe mode win32pipe |
| Proxy | ✅ 活跃 | Provider deepseek-v4-flash, 0.2-2.3s latency, 全部成功 |
| Queue | ✅ 空闲 | 无待处理命令 |
| Guardian V3 | ⚠️ 静默 | 自 Jun 9 09:19 后无更新 (需宿主机侧排查) |
| Provider 熔断器 (Jun 5) | ✅ 已解决 | 已切换到 deepseek 提供商, 无复发 |

---

## 日志

- [Self-Evolution Log](../docs/self-evolve-log.md) — 每次 self-evolve 运行的完整记录
