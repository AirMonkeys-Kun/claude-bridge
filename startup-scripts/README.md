# 启动脚本

## start-local-dev.sh（当前主力）

**位置：** `D:\zebbingo\scripts\start-local-dev.sh`（WSL 路径：`/home/administrator/projects/start-local-dev/start-local-dev.sh`）

通过 nohup + PID 文件管理 4 个服务，所有脚本和服务运行在 WSL 内部。

### 用法

```bash
bash start-local-dev.sh start|stop|restart|status [all|chatbot|stt]
```

### PID 文件

```
/tmp/start-local-dev/
├── bot_runner.pid
├── stt_backend.pid
├── frontend_dev.pid
├── mqtt_worker.pid
├── service_profiles.json
```

### 管理机制

- 使用 `nohup ... > logfile 2>&1 &` 后台启动
- PID 文件存储进程 ID
- `status` 命令通过 `kill -0` 检查进程存活
- `stop` 命令通过 `kill` + 等待超时 `kill -9` 停止

---

## start-stt-platform.ps1（旧方案）

**位置：** `D:\zebbingo\scripts\start-stt-platform.ps1`

Windows PowerShell 方案，通过 `wsl.exe` 启动 WSL 内的后端，通过 `pnpm run dev` 在 Windows 上启动前端 dev server（port 5173）。

### 用法

```powershell
.\start-stt-platform.ps1 -Action start|stop|status|restart
```

### PID 文件

```
%TEMP%\start-stt-platform\
```

### 与主方案的区别

| 特性 | start-local-dev.sh | start-stt-platform.ps1 |
|------|-------------------|----------------------|
| 运行环境 | WSL bash | Windows PowerShell |
| 前端方式 | 构建后 dist 文件 | pnpm dev server (5173) |
| 服务面板集成 | 有 (ServiceManager.vue) | 无 |
| 启动入口 | 后端 API 触发 | 手动运行 |
| 服务数量 | 4 个 | 2 个 (backend + frontend) |
