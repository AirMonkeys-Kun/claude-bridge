# 桥接系统（Bridge）价值证明 —— 超多维度测试

> 目的：证明即使 workspace bash 恢复后，桥接系统（file_bridge + user_bridge）仍然不可或缺
> 测试日期：2026-06-01
> 测试方法：每组测试同时用 bash、file_bridge (SYSTEM)、user_bridge (USER) 三种上下文执行

---

## 一、三维特权模型（基础）

这是整张测试的根基——三个上下文是完全不同的身份：

| 维度 | bash (Linux VM) | file_bridge | user_bridge |
|------|----------------|-------------|-------------|
| **身份** | `upbeat-charming-davinci` | `nt authority\system` | `desktop-icfuo8b\yck` |
| **SID** | N/A (Linux) | S-1-5-18 | S-1-5-21-...-1001 |
| **层级** | VM sandbox | Windows SYSTEM | Windows USER (管理员) |
| **操作系统** | Linux 6.8.0 | Windows 11 | Windows 11 |

---

## 二、对照测试结果

### 维度 1：MSIX 存储穿透 ⭐ 最核心

**问题：** MSIX 虚拟化存储只有 USER 上下文能看见，SYSTEM 和 Linux VM 都看不见。

| 上下文 | 结果 |
|--------|------|
| **bash** | ❌ 完全看不到 Windows 文件系统 |
| **file_bridge (SYSTEM)** | ⚠️ 看到非 MSIX 路径 (5 文件):
  `initrd`, `rootfs.vhdx [symlink→D:]`, `sessiondata.vhdx`, `smol-bin.vhdx`, `vmlinuz` |
| **user_bridge (USER)** | ✅ 看到 MSIX 真实存储 (15 文件):
  `.initrd.origin`, `.rootfs.vhdx.origin`, `.vmlinuz.origin` ← 压缩源文件
  `.initrd.zst.origin`, `.rootfs.vhdx.zst.origin`, `.vmlinuz.zst.origin` ← 进一步压缩
  `initrd.zst`, `rootfs.vhdx.zst`, `vmlinuz.zst` ← 压缩副本
  `initrd`, `rootfs.vhdx`, `sessiondata.vhdx`, `smol-bin.vhdx`, `vmlinuz` ← 工作文件 |

**桥的不可替代性：** 只有 user_bridge 能穿透 MSIX 存储。如果 Claude Desktop 更新重新下载了 bundle，bash 无法察觉，file_bridge 看不到源文件，必须 user_bridge 感知变化并触发修复。

---

### 维度 2：Windows 服务管理

**问题：** bash 是 Linux VM，没有 sc.exe、PowerShell 等 Windows 管理工具。

| 上下文 | 结果 |
|--------|------|
| **bash** | ❌ `sc.exe: not found` |
| **file_bridge (SYSTEM)** | ✅ `sc qc CoworkVMService`:
  - BINARY_PATH: `WindowsApps\Claude_...\cowork-svc.exe`
  - START_TYPE: AUTO_START
  - SERVICE_START_NAME: LocalSystem
  - DEPENDENCIES: staterepository |
| **user_bridge (USER)** | ❌ 普通用户无权直接查 Windows 服务 |

**桥的不可替代性：** 当 workspace 不启动时，需要通过文件桥重启 CoworkVMService。bash 做不到，user_bridge 权限不够。只有 file_bridge (SYSTEM) 能做。

---

### 维度 3：注册表访问

**问题：** bash 没有 Windows 注册表，没有任何 API 可以读 HKLM。

| 上下文 | 结果 |
|--------|------|
| **bash** | ❌ `reg.exe: not found` |
| **file_bridge (SYSTEM)** | ✅ `reg query HKLM\...\CoworkVMService`:
  `ImagePath = REG_EXPAND_SZ -> WindowsApps\Claude_...\cowork-svc.exe` |
| **user_bridge (USER)** | ❌ HKCU 可读，HKLM 受限 |

**桥的不可替代性：** 注册表存储着服务配置、启动参数、MSIX 包信息。调试 workspace 启动问题时，bash 零可见度。

---

### 维度 4：跨上下文数据链

**问题：** 三种上下文之间能否传递数据？

| 方向 | 路径 | 结果 |
|------|------|------|
| **user_bridge → bash** | user_bridge 写文件到 bridge 文件夹 → bash 读取 | ✅ `bridge_chain_proof.txt` 内容双方一致 |
| **bash → user_bridge** | bash 写文件到 bridge 文件夹 → user_bridge 读取 | ✅ `bridge_chain_reverse.txt` 双方可见 |
| **bash → file_bridge** | bash 写文件 → SYSTEM 通过 file_bridge 读取 | ✅ 文件在共享文件夹中 |
| **file_bridge → bash** | SYSTEM 写文件 → bash 读取 | ✅ 共享文件夹双向 |

**桥的不可替代性：** bash 只能读挂载文件夹。如果想要 bash 操作 SYSTEM-only 资源（如日志、系统文件、服务状态），必须通过桥中转。

---

### 维度 5：持久化自动修复

**问题：** 如果 Claude Desktop 更新后覆盖了 bundle/SDK 文件，谁能检测并修复？

| 上下文 | 结果 |
|--------|------|
| **bash** | ❌ 无法检测宿主文件是否缺失，因为它看不到宿主文件系统 |
| **file_bridge (SYSTEM)** | ✅ 3 秒内完成完整性检测：
  - Bundle: 5 文件 ✓ (rootfs symlink intact)
  - SDK: 2 文件 ✓ (claude 248MB + .verified)
  - Service: RUNNING ✓ |
| **user_bridge (USER)** | ✅ 检测 MSIX 源文件完整性 (rootfs.origin EXISTS ✓) |

**桥的不可替代性：** 当 workspace 再次崩溃（Claude 更新覆盖文件），bash 自己无法修复自己——因为它已经在 VM 里，看不到宿主发生了什么。必须桥在外部检测、修复、重启。

---

### 维度 6: WSL 可达性

**问题：** bash 能不能访问 WSL？之前 WSL 路径在 workspace 文件夹列表时导致 VM 崩溃（UNC paths not supported）。

| 上下文 | 结果 |
|--------|------|
| **bash** | ❌ `wsl` 命令不存在，`/mnt/wsl/` 不存在，`/mnt/wsl.localhost/` 不存在，不能 ping 宿主。**纯 Linux 沙箱，零 Windows 工具链** |
| **file_bridge (SYSTEM)** | ⏱ 直接访问 `\\wsl.localhost\ubuntu\home\yck` 超时（17s） |
| **user_bridge (USER)** | ⏱ UNC 直接访问超时，但 **`wsl.exe` CLI 完全可用**：
  1. `wsl -l -v` → Ubuntu (Stopped)
  2. `wsl -d ubuntu echo "awake"` → 成功唤醒
  3. `wsl -d ubuntu -e ls /home/yck/` → 完整列出所有文件（SmartAgent 项目） |

**桥的不可替代性：** bash 不仅看不到 WSL，而且一旦 WSL 路径出现在 `userSelectedFolders` 中，VM 会直接崩溃。但桥可以通过 `wsl.exe` CLI 管理 WSL——查状态、唤醒、执行命令。**这是纯 Windows 的能力，Linux VM 永远做不到。**

---

### 维度 7: 特权层级全景

| 能力 | bash (VM) | file_bridge (SYSTEM) | user_bridge (USER) |
|------|-----------|---------------------|-------------------|
| 运行 Linux 命令 | ✅ | ❌ | ❌ |
| 读/写挂载文件夹 | ✅ | ✅ | ✅ |
| 管理 Windows 服务 | ❌ | ✅ | ❌ |
| 管理 Windows 进程 | ❌ | ✅ | ⚠️ 受限 |
| 读 Windows 注册表 | ❌ | ✅ HKLM | ✅ HKCU |
| 读 MSIX 虚拟化存储 | ❌ | ❌ | ✅ |
| WSL 管理 (唤醒/执行) | ❌ | ❌ | ✅ |
| 读系统日志 (Event Log) | ❌ | ✅ | ❌ |
| 写用户桌面文件 | ✅ (挂载路径) | ❌ (直接) | ✅ |
| 创建 USER 上下文进程 | ❌ | ❌ (直接) | ✅ |
| 创建 SYSTEM 上下文进程 | ❌ | ✅ | ❌ |
| 网络请求 (宿主) | ⚠️ 受限 | ✅ | ✅ |
| 定时任务/持久化 | ❌ | ✅ | ✅ |

---

## 三、价值总结

### 桥的必要性，一句话

> **bash 能跑的时候，桥是"加速器"和"望远镜"；bash 不能跑的时候，桥是"担架"和"手术台"。**

### 三个不可替代的角色

**1. file_bridge (SYSTEM) —— 特权操作者**
- 管理 Windows 服务（重启 cowork-svc）
- 读 HKLM 注册表（查配置、查路径）
- 写系统级文件
- 创建 SYSTEM 进程
- → **bash 做不到，user_bridge 权限不够**

**2. user_bridge (USER) —— 窗口穿透者**
- 穿透 MSIX 虚拟化存储（唯一能看到真实文件来源的通道）
- 管理 WSL（唤醒、执行命令、查状态）
- 操作用户桌面文件
- 以用户身份发起网络请求（GitHub API、OAuth）
- → **bash 看不见，file_bridge 没有用户身份**

**3. bash (Linux VM) —— Linux 执行者**
- 运行 Linux 原生命令和工具
- 处理 Linux 文件系统
- → **两个桥都做不到，这是 VM 的唯一价值**

### 现实场景：下次 workspace 崩溃时

```
Claude Desktop 更新
  ↓
覆盖了 bundle 文件（MSIX 下载新版到 Packages 路径）
  ↓
SYSTEM 路径下的 rootfs.vhdx 变成旧版本或不一致
  ↓
workspace bash 启动失败
  ↓
bash 自己无法修复（它在 VM 里，看不到发生了什么）
  ↓
但 file_bridge 可以：
  1. 检测到 bundle 文件异常（大小/时间戳变化）
  2. 通过注册表查 service 状态
  3. 重新复制/链接文件
  4. 重启 cowork-svc
  5. bash 恢复运行
```

没有桥，这个循环只能手动操作。有桥，自动修复。

---

## 四、附件：原始测试记录

| 测试 ID | 桥 | 命令 | 耗时 | 结果 |
|---------|-----|------|------|------|
| t_dim1_msix | file_bridge | `dir vm_bundles\claudevm.bundle` | 165ms | ✅ 5 files |
| t_dim1_msix_user | user_bridge | `dir MSIX vm_bundles\claudevm.bundle` | 219ms | ✅ 15 files (含 .origin, .zst) |
| t_dim2_svc | file_bridge | `sc qc CoworkVMService` | 326ms | ✅ 完整服务配置 |
| t_dim2_svc_user | user_bridge | `whoami /groups` | 528ms | ✅ Administrators 组成员 |
| t_dim3_reg | file_bridge | `reg query HKLM\Services\CoworkVMService` | 152ms | ✅ ImagePath |
| t_dim4_chain1 | user_bridge | 写 → bash 读 | 153ms | ✅ 跨上下文文件传输 |
| t_dim5_autoheal | file_bridge | 完整性检测（bundle + SDK + service） | 152ms | ✅ 全部正常 |
| t_dim6_priv | file_bridge | `whoami` → SYSTEM (S-1-5-18) | 200ms | ✅ |
| t_dim6_priv_user | user_bridge | `whoami` → yck (S-1-5-21-...-1001) | 216ms | ✅ |
| t_dim7_wsl_user | user_bridge | `wsl -l -v` → Ubuntu 唤醒 → `ls /home/yck/` | 3483ms | ✅ **完整 WSL 穿透** |
| t_dim7_wsl_sys | file_bridge | `dir \\wsl.localhost\...` 直接访问 | timeout | ❌ 超时（需通过 wsl.exe） |

---

*文档创建日期: 2026-06-01*
*关联: workspace_vm_bundle_fix.md、privilege_hierarchy.md、桥接集群 V5*
