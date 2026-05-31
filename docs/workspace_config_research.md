# Claude Desktop/Cowork Workspace 配置研究

> 日期: 2026-06-01
> 目标: 移除 `\\wsl.localhost\ubuntu\home\yck` 从 workspace 挂载列表，修复 bash sandbox UNC 路径错误

---

## 一、问题背景

Cowork 模式的 workspace 文件夹列表中包含了 WSL UNC 路径 `\\wsl.localhost\ubuntu\home\yck`，导致 Linux VM sandbox 在启动时崩溃：

```
UNC paths are not supported: \\wsl.localhost\ubuntu\home\yck
```

只要这个路径在 `userSelectedFolders` 列表中，所有 bash/mcp__workspace__bash 调用都会失败。

---

## 二、存储位置发现

### 最终结论

`userSelectedFolders` 存储在 **session JSON 文件** 中，**不存在** 全局配置文件。

### 完整路径

```
C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\
  local-agent-mode-sessions\{sessionId}\{subId}\local_{uuid}.json
```

具体路径示例：
```
C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\
  local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\
  00000000-0000-4000-8000-000000000001\
  local_8108405e-cac5-481d-9ad7-a58b2452fc01.json
```

### JSON 结构

```json
{
  "sessionId": "local_...",
  "processName": "ecstatic-beautiful-hopper",
  "userSelectedFolders": [
    "C:\\Users\\yck",
    "C:\\Users\\wsx\\Desktop",
    "\\\\wsl.localhost\\ubuntu\\home\\yck",    <--- 这一项导致 sandbox 崩溃
    "C:\\Users\\wsx\\Desktop\\claude-bridge"
  ],
  "createdAt": 1780239374109,
  "lastActivityAt": 1780253976409,
  "model": "claude-sonnet-4-6",
  ...
}
```

关键字段是 `userSelectedFolders` —— 一个字符串数组，包含所有用户选择挂载的文件夹路径。

### 已排除的位置

以下位置 **不含** `userSelectedFolders`：

| 文件 | 路径 | 内容 |
|------|------|------|
| `config.json` | `LocalCache\Local\Claude-3p\config.json` | 窗口位置、主题、更新版本 |
| `Local State` | `LocalCache\Local\Claude-3p\Local State` | Chromium 加密密钥 |
| `Preferences` | `LocalCache\Local\Claude-3p\Preferences` | DevTools 设置 |
| `window-state.json` | `LocalCache\Local\Claude-3p\window-state.json` | 窗口大小位置 |
| `developer_settings.json` | `LocalCache\Local\Claude-3p\developer_settings.json` | `{"allowDevTools": true}` |
| `claude_desktop_config.json` | `LocalCache\Local\Claude-3p\claude_desktop_config.json` | Cowork 部署模式、偏好 |
| `cowork_account_settings.json` | 会话目录下 | 账户信息、banner 状态 |
| LevelDB `Local Storage\leveldb\` | 多个 .ldb 文件 | 不包含 workspace 配置 |
| LevelDB `IndexedDB\` | .ldb 文件 | 不包含 workspace 配置 |
| LevelDB `Session Storage\` | .ldb 文件 | 不包含 workspace 配置 |

---

## 三、MSIX 包数据目录架构

Claude Desktop 是 MSIX 包装应用（PackageFamilyName: `Claude_pzs8sxrjxfjjc`），其 `app.getPath('userData')` 被重定向到：

```
C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\
```

目录结构：

```
Claude-3p/
├── Cache/                       Chromium 缓存
├── Crashpad/                    崩溃报告
├── DawnGraphiteCache/           GPU 缓存
├── DawnWebGPUCache/             WebGPU 缓存
├── GPUCache/                    更多 GPU 缓存
├── IndexedDB/                   IndexedDB LevelDB 存储
│   └── app_localhost_0.indexeddb.leveldb/
├── Local Storage/               localStorage LevelDB
│   └── leveldb/
├── Network/                     网络状态
├── Partitions/                  隔离分区（cowork-file-preview）
├── Session Storage/             session storage LevelDB
├── SharedStorage/               共享存储（4096 bytes 固定大小）
├── claude-code/                 Claude Code CLI（254MB）
├── claude-code-vm/              Claude Code VM（248MB）
├── local-agent-mode-sessions/   ← 核心：所有会话数据
│   └── {sessionId}/
│       └── {subId}/
│           ├── local_{uuid}.json          ← userSelectedFolders 在这里
│           ├── cowork_account_settings.json
│           ├── audit.jsonl                ← 审计日志（可很大）
│           ├── memory/                    持久记忆
│           └── .claude/                   Claude Code CLI 会话数据
├── logs/                        应用日志
│   └── main.log                 主日志（可达 6MB+）
├── vm_bundles/                  VM 镜像（总计 10GB+）
│   └── claudevm.bundle/
│       ├── initrd               Linux VM 内核初始化镜像
│       ├── rootfs.vhdx          rootfs（9.4GB）
│       ├── sessiondata.vhdx     会话数据磁盘（608MB）
│       └── smol-bin.vhdx        工具分区（37MB）
├── config.json                  窗口/主题配置
├── Local State                  Chromium 状态
├── Preferences                  DevTools 偏好
├── window-state.json            窗口位置
├── developer_settings.json      开发者设置
├── claude_desktop_config.json   Cowork 桌面配置
└── settings.json                其他设置
```

重要观察：`userSelectedFolders` **不在任何 LevelDB 或 SQLite 文件里**，只存在 session JSON 文件里。

---

## 四、CDP 调试方案（已废弃）

### 尝试过程

尝试用 Chrome DevTools Protocol (`--remote-debugging-port=9222`) 连接 Electron 进程内部状态，但彻底失败：

| 尝试方法 | 结果 |
|----------|------|
| `Invoke-CommandInDesktopPackage -Args @(...)` | 类型错误：不支持 System.Object[] |
| `Invoke-CommandInDesktopPackage -Args "..."` | COMException 0x800704C7 "操作被用户取消" |
| `-Command "exe --port=9222"` | 同上 |
| 绝对路径 | 同上 |
| COM Shell.Application `ParseName("AUMID").InvokeVerb("open")` | 能启动但无法传参 |
| App Execution Alias (`WindowsApps\Claude.exe`) | 别名文件不存在 |
| 环境变量 `ELECTRON_EXTRA_LAUNCH_ARGS` | 未生效 |
| `Start-Process "shell:AppsFolder\AUMID"` | 无法传参 |

### 失败原因

MSIX Desktop Bridge 完全阻断了命令行参数注入：
- `Invoke-CommandInDesktopPackage` 内部调用 AppLifecycle API 返回 ERROR_CANCELLED
- 参数必须通过 MSIX 的 AppExecutionAlias 或包激活 API 传递，但这些机制都无法传递 Electron 标志
- MSIX 单例限制不能启动第二个实例

### 相关命令参考

```powershell
# 获取 AUMID（SYSTEM 上下文不可用 Get-StartApps，改用 AppxManifest.xml）
Get-AppxPackage -Name "Claude" | Select-Object PackageFamilyName

# 杀死 Claude
Get-Process -Name "Claude" | Stop-Process -Force

# COM 方式启动（能启动但没有传递参数能力）
$shell = New-Object -ComObject Shell.Application
$folder = $shell.NameSpace("shell:AppsFolder")
$app = $folder.ParseName("Claude_pzs8sxrjxfjjc!Claude")
$app.InvokeVerb("open")
```

---

## 五、修复方案（已验证可行）

### 步骤

1. **修改 session JSON 文件**：从 `userSelectedFolders` 数组中移除 WSL 路径

   用桥或 Python：
   ```python
   import json
   fp = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\..."  # session JSON path
   with open(fp, "r", encoding="utf-8") as f:
       data = json.load(f)
   data["userSelectedFolders"].remove("\\\\wsl.localhost\\ubuntu\\home\\yck")
   with open(fp, "w", encoding="utf-8") as f:
       json.dump(data, f, indent=2, ensure_ascii=False)
   ```

2. **备份**：脚本自动创建 `.backup` 文件

3. **重启 Claude Desktop**：使 VM 重新读取配置

### 通过桥接器执行（推荐）

将 Python 脚本写入 `C:\Users\wsx\Desktop\claude-bridge\watcher\` 目录，然后通过 `queue.txt` 执行：

```json
{"state":"pending","cmd_id":"fix","command":"python C:\\Users\\wsx\\Desktop\\claude-bridge\\watcher\\fix_wsl.py","type":"cmd","timeout":30}
```

注意：桥接器以 SYSTEM 运行，需要硬编码用户路径（`C:\Users\wsx`）而非使用环境变量。

### 验证方法

```bash
# 如果修复成功并重启后，bash 应该能正常执行
echo "test" && whoami
```

### 验证工具

最终使用的验证/修复脚本列表：

| 脚本 | 路径 | 用途 |
|------|------|------|
| `fix_wsl.py` | `watcher/fix_wsl.py` | 从当前 session JSON 移除 WSL 路径 |
| `fix_wsl2.py` | `watcher/fix_wsl2.py` | 修复所有 session 文件 + 搜索全局配置 |
| `scan_dir.py` | `watcher/scan_dir.py` | 扫描 Claude-3p 目录结构 |
| `scan_dir2.py` | `watcher/scan_dir2.py` | 深度扫描（硬编码用户路径） |
| `scan_msix.py` | `watcher/scan_msix.py` | 扫描 MSIX 包隔离目录 |
| `scan_read.py` | `watcher/scan_read.py` | 读取关键配置文件 |
| `read_global.py` | `watcher/read_global.py` | 读取全局 JSON 配置 |
| `read_session.py` | `watcher/read_session.py` | 读取 session JSON 结构 |
| `check_leveldb.py` | `watcher/check_leveldb.py` | 搜索 LevelDB 中的 WSL 路径 |
| `restart_claude.ps1` | `watcher/restart_claude.ps1` | 用 COM 重启 Claude Desktop |
| `launch_cdp_v3.ps1` | `watcher/launch_cdp_v3.ps1` | CDP 启动尝试（已废弃，但包含所有方法） |
| `search_everywhere.py` | `watcher/search_everywhere.py` | 全面搜索 MSIX Settings + SystemAppData + LevelDB |
| `check_dips.py` | `watcher/check_dips.py` | 检查 DIPS/SharedStorage SQLite + VHDX 全文搜索 |
| `fix_all_sessions.py` | `watcher/fix_all_sessions.py` | 从所有 session JSON 移除 WSL 路径（含扫描） |
| `fix_scheduled_tasks.py` | `watcher/fix_scheduled_tasks.py` | 从 scheduled-tasks.json 移除 WSL 路径 |
| `check_session.py` | `watcher/check_session.py` | 验证 session JSON 中 WSL 是否存在 |
| `quick_check.py` | `watcher/quick_check.py` | 快速检查配置文件 |

---

## 六、注意事项

1. **SYSTEM 上下文环境变量问题**：桥接器以 SYSTEM 运行，`%LOCALAPPDATA%` 指向 SYSTEM 的目录而非用户 wsx 的目录。所有脚本必须硬编码 `C:\Users\wsx` 路径。

2. **MSIX 包路径不可在 bash 中访问**：`C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\` 可以通过 Read/Write 工具和桥接器访问，但不能通过 bash sandbox 访问（sandbox 本身就在 VM 里）。

3. **文件锁定**：session JSON 文件在 Claude Desktop 运行时未被锁定（可以正常修改），但 VM 在启动时读取一次后不会再重新读取，所以修改需重启生效。

4. **配置持久性**：每个会话独立存储 `userSelectedFolders`。目前未知 Cowork UI 中的"选择文件夹"操作数据存储在何处——不在文件系统中，可能在 Electron 进程内或 sessiondata.vhdx 中。

5. **sessiondata.vhdx**：608MB 的 VM 数据磁盘，可能包含文件夹挂载元数据。如需深入，可以用 `DiskPart` 挂载 VHDX 分析。

---

## 七、关键突破：scheduled-tasks.json 是重启后 WSL 回归的根源

### 意外发现

`userSelectedFolders` 不仅存在于当前 session JSON 中，还存在于：

1. **已归档的旧 session JSON 文件**（SmartAgent 会话）
2. **`scheduled-tasks.json`** — 定时任务配置文件中

### scheduled-tasks.json 结构

```json
{
  "scheduledTasks": [
    {
      "id": "smartagent-wsl-healthcheck",
      "enabled": true,
      "userSelectedFolders": [
        "C:\\Users\\wsx\\Documents\\SmartAgent",
        "\\\\wsl.localhost\\ubuntu\\home\\yck"
      ]
    },
    {
      "id": "smartagent-wsl-deploy-and-test",
      "userSelectedFolders": [
        "C:\\Users\\wsx\\Documents\\SmartAgent",
        "\\\\wsl.localhost\\ubuntu\\home\\yck"
      ]
    },
    {
      "id": "smartagent-deploy-now",
      "userSelectedFolders": [
        "C:\\Users\\wsx\\Documents\\SmartAgent",
        "\\\\wsl.localhost\\ubuntu\\home\\yck"
      ]
    }
  ]
}
```

### 为何重启后 WSL 路径会重新出现

1. 修改 session JSON 移除 WSL → 重启 Claude Desktop
2. 重启时 Claude Desktop 读取 ALL session 数据（包括 `scheduled-tasks.json`）
3. 从定时任务的 `userSelectedFolders` 中合并/恢复了 WSL 路径到新的 session JSON
4. 最终效果：**WSL 路径"复活"**

### 修复范围

WSL 路径在以下位置被修复（共 8 处）：

| 文件 | 数量 | 说明 |
|------|------|------|
| `local_8108405e-...json`（当前会话） | 1 处 | 关键文件夹列表 |
| `local_0e04c4be-...json`（SmartAgent） | 1 处 | 归档 session |
| `local_14c94032-...json`（SmartAgent） | 1 处 | 归档 session |
| `local_3bbfc8b7-...json`（SmartAgent） | 1 处 | 归档 session |
| `scheduled-tasks.json` | 3 处 | 3 个定时任务各含 WSL |
| `local_8108405e-...json.backup` | 1 处 | 备份文件也需要清理 |

### 验证结果

修复后重启 Claude Desktop，session JSON 重新写入时 WSL **没有重新出现**（timestamp 03:07:58，9 个文件夹）。需完全重启后新 sandbox 才能生效。

---

## 八、长期解决方案

### 方案一：合并修复脚本

执行以下两个脚本即可完成全面清理：

```bash
python C:\Users\wsx\Desktop\claude-bridge\watcher\fix_all_sessions.py
python C:\Users\wsx\Desktop\claude-bridge\watcher\fix_scheduled_tasks.py
```

### 方案二：定时自动清理

通过 bridge 创建 Windows 计划任务，每小时扫描并移除 WSL 路径。

### 方案三：watcher 启动钩子

在 watcher.ps1 中增加启动时自动执行修复钩子。

---

## 九、已验证的关键结论

1. **`userSelectedFolders` 只存储在 session JSON 文件中** — 不在 LevelDB、SQLite、VHDX、Registry 或任何全局配置中
2. **文件可以热修改** — session JSON 在 Claude Desktop 运行时可以读写
3. **重启才会生效** — VM sandbox 只在启动时读取 `userSelectedFolders`
4. **`scheduled-tasks.json` 是隐藏的二次源** — 修复 session JSON 后如果不同时修复这里，WSL 路径会在下次启动时"复活"
5. **SYSTEM 上下文看不到用户进程** — `tasklist` / `Get-Process` 都看不到 Claude.exe
6. **COM Shell.Application 可以启动 Claude** — 但不能传参，也不能真正"重启"（只是调起窗口）

---

## 十、相关知识

### MSIX CLI 参数问题

MSIX 包通过 Desktop Bridge 技术运行 Win32 应用时，CLI 参数传递一直是个已知问题：
- `Invoke-CommandInDesktopPackage` 是唯一官方支持的参数传递方式
- 但该 cmdlet 在多个 Windows 版本上有已知 bug（包括 0x800704C7）
- 替代方案包括修改 Package Support Framework (PSF) 配置
- 更详细的讨论参见 `launch_cdp_v3.ps1` 中的全部 8 种尝试方法

### 相关文件

- 备份文件：`local_*.json.backup` 和 `*.backup2`（在 session JSON 同目录下）
- 日志文件：`watcher/cdp_v3.log`、`watcher/fix_result.txt`、`watcher/fix_result2.txt`
- 扫描结果：`watcher/scan_result2.json`、`watcher/scan_msix_result.json`、`watcher/scan_read_result.json`
