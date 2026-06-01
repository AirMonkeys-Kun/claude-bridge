# Claude Desktop Workspace VM 启动失败 —— 完整修复记录

> 问题现象、根因分析、三轮修复、社区 Issue 对照、多角度总结、本机 vs 原 Issue 对比

---

## 一、问题现象

```
mcp__workspace__bash 失败: "The isolated Linux environment failed to start"
```

错误日志位于：
`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\logs\cowork_vm_node.log`

---

## 二、根本原因

Claude Desktop 以 MSIX（AppX）包安装后，VM bundle 文件和 SDK 文件被下载到 **MSIX 虚拟化存储**（仅 USER 上下文可见），但：

- **cowork-svc.exe**（VM 管理器）以 **SYSTEM 上下文**运行，去**非 MSIX 路径**找文件
- **SYSTEM 看不到 MSIX 存储**——这是 Windows MSIX 的架构隔离限制，非 bug

### 路径对照

| 位置 | 路径 | 谁用 |
|------|------|------|
| MSIX 存储（USER 可见） | `Packages\Claude_...\LocalCache\Local\Claude-3p\...` | 下载器、USER 进程 |
| 非 MSIX 路径（SYSTEM 可见） | `AppData\Local\Claude-3p\...` | cowork-svc、Hyper-V 管理器 |

---

## 三、三条修复线

同一个根因（MSIX 路径隔离）在三层暴露不同症状，需要三种不同的修复手法。

### 修复线 1：Bundle 文件 "not found"

**症状：**
```
[error] [VM:start] Startup failed: Error: failed to set VHDX path:
VHDX file not found: C:\...\claudevm.bundle\rootfs.vhdx
```

**原因：** rootfs.vhdx（9.4 GB）在 MSIX 存储中，cowork-svc 在非 MSIX 路径找不到。

**方案 V1（首次尝试）：目录级符号链接**
```
C 盘不足（7.74 GB free < 9.4 GB）→ 复制到 D:（172 GB free）
→ 创建目录符号链接 D:\vm_bundles\claudevm.bundle → C:\...\claudevm.bundle
```
结果：✅ 文件找到了，但下一层出问题。

### 修复线 2：cowork-svc 拒绝符号链接

**症状：**
```
[error] [VM:start] Startup failed: Error: configure: path C:\...\claudevm.bundle
is a symlink or junction, refusing to open
```

**原因：** cowork-svc 显式检查 bundle 路径是否为 reparse point，拒绝跟随。

**方案 V2（最终方案）：真实目录 + 文件级符号链接**
```
1. 删除目录符号链接
2. 在 C:\...\claudevm.bundle\ 创建真实目录
3. 直接复制小文件（smol-bin 36MB、vmlinuz 14MB、initrd 169MB、sessiondata 580MB）
4. rootfs.vhdx（9.4GB）单独做文件级符号链接指向 D:
```
```
C:\...\claudevm.bundle\           ← 真实目录（非 reparse point）
├── smol-bin.vhdx                 ← 直接复制（36 MB）
├── vmlinuz                       ← 直接复制（14 MB）
├── initrd                        ← 直接复制（169 MB）
├── sessiondata.vhdx              ← 直接复制（580 MB）
└── rootfs.vhdx ──[symlink]──→ D:\vm_bundles\claudevm.bundle\rootfs.vhdx (9.4 GB)
```
结果：✅ VM 成功启动，网络连通，但 SDK 安装出问题。

### 修复线 3：SDK 二进制 VirtioFS I/O 错误

**症状：**
```
[error] [VM:start] Startup failed: Error: RPC error -1: failed to open SDK binary:
open /mnt/.virtiofs-root/shared/.../claude-code-vm/2.1.128/claude: input/output error
```

**原因：** SDK 文件（~250MB）同样在 MSIX 存储中。cowork-svc 通过 **VirtioFS（Plan9 共享）** 将宿主目录映射到 VM 内部。当 SDK 目录为 junction 时，VirtioFS 无法穿越 reparse point，报 I/O 错误。

**方案 V3（最终方案）：直接复制 SDK 到非 MSIX 路径**
```
1. 删除 claude-code-vm junction
2. 在 C:\...\Claude-3p\claude-code-vm\2.1.128\ 创建真实目录
3. 直接复制 SDK 文件（.sdk-version, .verified, claude binary 248MB）
```
结果：✅ VM 完整启动，bash 正常工作。

**文件清单：**

| 文件 | 大小 |
|------|------|
| `claude-code-vm\.sdk-version` | 7 B |
| `claude-code-vm\.verified` | 0 B |
| `claude-code-vm\2.1.128\.verified` | 0 B |
| `claude-code-vm\2.1.128\claude` | 248 MB |

---

## 四、三条不同的修复路径（三台不同机器/场景对照）

同一个 MSIX 路径隔离问题，在不同环境中表现出不同症状，需要用不同手法修复。

| 场景 | 机器 | 症状 | 修复方案 | 原因 |
|------|------|------|----------|------|
| **Issue #62430** | Win10 Pro, Store/AppX 安装 | Roaming 路径找不到 bundle | **硬链接**（New-Item HardLink） | AppX 包将文件写入 MSIX 存储，服务找 Roaming 路径 |
| **本机 V1** | Win11, MSIX 安装 | SYSTEM 路径找不到 bundle | **目录符号链接** + D: 盘 | C 盘空间不足，symlink 绕道 D: |
| **本机 V2（最终）** | Win11, MSIX 安装 | cowork-svc 拒绝 symlink + VirtioFS I/O 错误 | **真实目录** + 文件级 symlink + SDK 直接复制 | 需两处修复：bundle 和 SDK |

### 已验证的无效方案

| 方案 | 原因 |
|------|------|
| `mklink /J`（junction） | bundle 路径：cowork-svc 拒绝；SDK 路径：VirtioFS I/O 错误 |
| 目录级符号链接 | cowork-svc 显式检查并拒绝 |
| 同一卷硬链接 | rootfs.vhdx 9.4GB，C 盘只剩 7.74GB，无法同卷创建 |

---

## 五、多角度分析

同一个问题可以从不同视角切入，得出不同的结论：

| 分析角度 | 视角 | 发现 |
|---------|------|------|
| **基础设施层** | VM bundle 文件路径、cowork-svc 启动流程、VirtioFS 共享 | 文件在 MSIX 存储中，服务在非 MSIX 路径找；VirtioFS 不穿越 reparse point |
| **特权层级层** | SYSTEM vs USER 上下文、MSIX 存储隔离、session 0 vs session 1 | SYSTEM 不含 USER 能力，看不到 MSIX；需要 user_bridge 做 token 复制 |
| **社区/Issue 层** | #62430、#36298、#24962、#30179 等 | 多台机器、多 Windows 版本、多安装方式遇到同类问题；MSIX 路径虚拟化是通用根因 |
| **用户经验层** | 同一用户的两台机器 | Win10 用硬链接修复、Win11 用符号链接/直接复制修复，不同变体同一根因 |

**核心洞察：**
- 问题根因是单一的（MSIX 路径虚拟化导致 SYSTEM 看不到 USER 文件）
- 但它在不同 Windows 版本、不同安装方式、不同文件类型（VHDX vs SDK）、不同服务（cowork-svc vs VirtioFS）中 **表现出三种不同的症状**
- 单层修复（只修文件路径）不够——需要理解整个链路：**文件系统 → 服务路径检查 → VirtioFS 共享 → SDK 验证**
- 特权层级模型（user_bridge / SYSTEM→USER token 复制）是从根本上弥补 MSIX 架构缺陷的方案

---

## 六、本机修复 vs Issue #62430 原修复 —— 深度对比

### 两种修复的路径对照

```
#62430（Win10, 2024-2025）
  用户发现: bundle 在 MSIX 存储里，服务在 Roaming 找
      ↓
  修复: 硬链接直接映射文件
      ↓
  视角: 单文件路径
      ↓
  结果: ✅ 修好了（当时只裂到第一层）


本机（Win11, 2026-06-01）
  用户发现: bundle 在 MSIX 存储里，服务在 Local 找
      ↓
  修复线1: 目录 symlink → 文件找到了
      ↓
  修复线2: cowork-svc 拒绝 symlink → 真实目录 + 文件级 symlink
      ↓
  修复线3: VirtioFS 读不到 SDK → 直接复制
      ↓
  视角: 完整特权链路
      ↓
  结果: ✅ 修好了 + 理解了整个架构
```

### 本质对比

| 维度 | Issue #62430（Win10） | 本机修复（Win11） |
|------|----------------------|-------------------|
| **看到的问题** | bundle 不在 Roaming 路径 | bundle 不在 SYSTEM 路径 |
| **修复手法** | 硬链接（New-Item HardLink） | 真实目录 + 文件级 symlink + SDK 直接复制 |
| **修复深度** | 单层（文件路径层） | 三层（文件→路径检查→VirtioFS/SDK） |
| **发现问题数** | 1 个 | 3 个（依次暴露） |
| **对架构的理解** | "文件在别处" | "SYSTEM 看不到 USER 的世界" |
| **工具链** | 纯 PowerShell 脚本 | 桥接集群（user_bridge + file_bridge） |
| **可维护性** | Claude 更新可能覆盖 | 完整链路文档 + 检查清单 |
| **风险覆盖** | 只有已知症状 | 三层各有一个防御方案 |

### 为什么 #62430 只遇到了一层

不是 Win10 的问题比 Win11 简单，而是**裂缝在 Win10 上只裂到了一层**：

1. **路径不同**：Win10 Store/AppX 安装的 Roaming 漫游路径 vs Win11 MSIX 的 Local 路径
2. **cowork-svc 版本不同**：新版本加入了 reparse point 检查（之前允许 symlink）
3. **SDK 部署方式不同**：新版本通过 VirtioFS 共享 SDK 到 VM，老版本可能直接用本地路径

**所以 #62430 的硬链接修复在当时是对的，但它是"够用"的修复，不是"完整"的修复。** 它解决了症状，但没有揭示架构缺陷。

### 从"修问题"到"理解问题"

```
#62430 的修复者：解决问题的人
  看到文件不存在 → 把文件链接过去 → 好了 → 结束

本机修复后的我们：理解问题的人
  看到文件不存在 → 问为什么不存在 → 
  发现 MSIX 隔离 → 发现 SYSTEM vs USER → 
  发现 symlink 检查 → 发现 VirtioFS 限制 →
  发现 SDK 部署路径 → 搭建桥接系统 →
  → 不是修好了一个 bug，而是绘制了一整张架构地图
```

### 关键区别

- **第一次修**是**平面的**：看到文件不见了，把它链过去。硬链接恰好绕过了 symlink 检查，但修的人并不知道有这层检查存在。
- **第二次修**是**立体的**：每一层的修复都揭示了下一层的存在。目录 symlink → 发现 cowork-svc 检查 symlink → 发现 VirtioFS 不穿越 junction → 发现 SDK 也在 MSIX 里。
- **真正的成果不是 workspace 能跑了，而是摸清了 MSIX 环境下 SYSTEM/USER 两个世界之间的完整地图。** 下次任何一层再出问题，十分钟就能定位根因。

---

## 附：Bash 开关实验

> 目的：bash VM 运行时消耗资源（CPU/内存 ~400MB+），不需要时可以受控断开

### 原理

利用第一条修复线（Layer 1）的失败模式：cowork-svc 启动时找不到 rootfs.vhdx 会快速失败。

```
断开: ren rootfs.vhdx rootfs.vhdx.off → taskkill cowork-svc → bash 快速失败
恢复: ren rootfs.vhdx.off rootfs.vhdx → sc start CoworkVMService → bash 恢复
```

### 操作方式

通过 file_bridge（SYSTEM 上下文）执行，因为 symlink 在 SYSTEM 可见的非 MSIX 路径中。

**断开 bash：**
```json
{"state":"pending","cmd_id":"bash_off","command":"cmd /c ren C:\\...\\rootfs.vhdx rootfs.vhdx.off && taskkill /f /im cowork-svc.exe","type":"cmd","timeout":15}
```
结果：~270ms，VM 服务被 kill，bash 调用立即失败。

**恢复 bash：**
```json
{"state":"pending","cmd_id":"bash_on","command":"cmd /c ren C:\\...\\rootfs.vhdx.off rootfs.vhdx && taskkill /f /im cowork-svc.exe && timeout /t 3 && sc start CoworkVMService","type":"cmd","timeout":30}
```
注意：恢复比断开复杂，因为 `sc start` 可能卡在 START_PENDING，需要 `taskkill` 先杀干净再启动。

### 实测结果

| 操作 | 耗时 | 结果 |
|------|------|------|
| 断开（ren + taskkill） | 268ms | ✅ bash 立即断开 |
| 恢复（ren + taskkill + sc start） | 8-12s | ⚠️ 成功但 sc start 有时卡住 |

### 局限性

1. **恢复不可靠**：`sc stop CoworkVMService` 常卡在 STOP_PENDING（WIN32_PACKAGED_PROCESS 特性），必须用 `taskkill` 强杀。
2. **多次重启后服务僵死**：反复 `taskkill` 可能让服务陷入"RUNNING 但 VM 连不上"的状态。此时只能重启 Claude Desktop 或等待超时恢复。
3. **没有软开关**：目前方案是直接操作文件系统，不是优雅的服务暂停/恢复。

### 与桥的关系

这个开关本身就是桥价值的证明：bash 能通过 rename symlink + kill 禁用自己吗？不能——它在 VM 里，看不到宿主文件系统。但 file_bridge（SYSTEM）可以，**因为桥在 bash 之外**。

---

## 七、相关 Issue

- [Issue #62430 - Cowork sandbox VM bundle not found in Roaming path on Windows 10 Pro](https://github.com/anthropics/claude-code/issues/62430) — 本机用户 AirMonkeys-Kun 提交，硬链接修复
- [Issue #36298 - VM bundle path mismatch (Roaming vs Local\Packages)](https://github.com/anthropics/claude-code/issues/36298)
- [Issue #24962 - Cowork VM fails on Win11 Home (missing sessiondata.vhdx)](https://github.com/anthropics/claude-code/issues/24962)
- [Issue #30179 - DCOM 10016 blocks CoworkVMService from MSIX container](https://github.com/anthropics/claude-code/issues/30179)
- [LINUX DO - 记一次给claude desktop的虚拟机擦屁股的经历](https://linux.do/t/topic/2100823)
- [CSDN - Claude桌面端Workspace启动失败的完整解决方案](https://wenku.csdn.net/doc/714a1xft4a4o)

---

## 八、修复后验证

```bash
$ whoami
upbeat-charming-davinci
$ uname -a
Linux claude 6.8.0-106-generic #106~22.04.1-Ubuntu x86_64
$ free -h
Mem: 3.8Gi total, 3.4Gi available
$ df -h /
/dev/sda1  9.6G  7.3G  2.3G  77% /
```

---

## ❗ 如果再次出现

1. 检查 `%LOCALAPPDATA%\Claude-3p\vm_bundles\claudevm.bundle\` 是否真实目录（非 symlink/junction）
2. 检查 `%LOCALAPPDATA%\Claude-3p\claude-code-vm\` 是否真实目录
3. 如果 bundle 或 SDK 被 Claude Desktop 更新覆盖，重复修复线的步骤
4. 重启 cowork-svc，然后重启 Claude Desktop

---

*文档创建日期: 2026-06-01*
*关联: 桥接集群 V5、Issue #62430、PS 5.1 陷阱知识库*
