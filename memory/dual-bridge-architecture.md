---
name: dual-bridge-architecture
description: 双桥架构总览 — 代理桥 (localhost:4000, AI 推理) + 通信桥 (queue.txt, 宿主机操作)，组合使 Claude 能力质变
type: project
---

Claude 在 Cowork 中通过两座桥突破能力边界：

**代理桥 (Proxy Bridge)** — `D:\zebbingo\tools\claude-desktop-config\proxy\server.py` V13, localhost:4000
- 让 Claude 使用 xiaomi mimo / zhipu GLM 后端，保持完整 Anthropic API 兼容
- Adaptive thinking 透传：模型自决定思考深度，不再强制固定 budget
- 多 provider 容错：熔断器 + 自动 failover
- 性能：代理开销 < 50ms，后端延迟 2-5s

**通信桥 (Communication Bridge)** — `D:\zebbingo\tools\claude-bridge\watcher\` V2.2
- 让 Claude 在 VM 沙箱内执行宿主机操作（PowerShell、文件、进程、服务）
- queue.txt 文件 IPC → watcher 分发 → Named Pipe 直连 worker
- 性能：echo round-trip 161-209ms，脚本执行 ~1.4s

**组合效果：** Claude 从"只能聊天"变成"能操作宿主机的全栈助手"。代理桥负责 AI 推理（便宜 + 多模型），通信桥负责执行能力（PowerShell + 文件 + 进程管理）。

**Why:** Cowork VM 沙箱隔离了 Claude 和宿主机，双桥分别解决了"用什么模型推理"和"怎么操作宿主机"两个核心限制。

**How to apply:** 需要推理 → 自动走代理桥；需要执行宿主机操作 → 写 queue.txt 走通信桥；两者可交替使用，互不干扰。

**详细文档：** `D:\zebbingo\tools\claude-bridge\docs\dual-bridge-architecture.md`
