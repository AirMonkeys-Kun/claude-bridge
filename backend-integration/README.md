# 后端集成 — 服务管理面板

## 概述

`stt-test-tool` 的后端（`server.py`）通过直接调用 WSL 内的 `start-local-dev.sh` 脚本来管理服务，不需要经过 Windows 的 queue.txt 桥。

## 架构

```
┌───────────────┐     HTTP API      ┌────────────────────┐
│  Vue 前端      │ ←─────────────── │  server.py (WSL)   │
│  ServiceManager│  /api/services/* │  FastAPI 后端       │
│  .vue          │                  │                     │
└───────────────┘                   │  subprocess.run()   │
                                     │  → bash             │
                                     │  start-local-dev.sh │
                                     └────────┬───────────┘
                                              │
                                     ┌────────▼───────────┐
                                     │  start-local-dev.sh │
                                     │  (WSL bash 脚本)    │
                                     │  nohup + PID 管理   │
                                     │  4 个服务           │
                                     └────────────────────┘
```

## 关键代码

### `_run_svc_script()` — server.py

```python
def _run_svc_script(action: str, suite: str = "all") -> dict:
    """Run start-local-dev.sh and return result."""
    env = os.environ.copy()
    active_profiles = _load_active_profiles()
    # 注入 profile 环境变量覆盖
    for group_name, profile_name in active_profiles.items():
        group_def = _PROFILE_GROUPS.get(group_name)
        if group_def:
            profile = group_def["available"].get(profile_name)
            if profile:
                env.update(profile["env"])
    try:
        result = subprocess.run(
            ["bash", _SERVICE_SCRIPT, action, suite],
            capture_output=True, text=True, timeout=120,
            env=env,
        )
        ...
```

### API 端点

| 端点 | 方法 | 说明 |
|------|------|------|
| `/api/services` | GET | 获取所有服务状态 |
| `/api/services/start/{suite}` | POST | 启动服务套件 |
| `/api/services/stop/{suite}` | POST | 停止服务套件 |
| `/api/services/restart/{suite}` | POST | 重启服务套件 |
| `/api/services/annotations` | GET | 获取服务描述和环境变量注释 |
| `/api/services/{service_id}/env` | GET | 获取服务当前环境变量值 |
| `/api/services/{service_id}/profiles` | POST | 切换 profile 并重启服务 |

### 服务配置文件

```
/tmp/start-local-dev/service_profiles.json
```

存储当前激活的 profile 组合：
```json
{
  "mqtt": "local",
  "mqtt": "cloud"
}
```

## 环境变量 Profile 系统

| Profile | MQTT 主机 | MQTT 端口 | CHATBOT_MQTT_ENV |
|---------|-----------|-----------|-------------------|
| local | 127.0.0.1 | 1883 | prod |
| cloud | AWS IoT Core eu-west-2 | 8883 (TLS) | production |

## 四类服务

| 服务 ID | 服务名 | 端口 | 所属套件 |
|---------|--------|------|----------|
| bot_runner | Bot Runner | 7860 | all, chatbot |
| stt_backend | STT Backend | 8765 | all, stt |
| frontend_dev | Frontend Dev | 3000 | all, chatbot |
| mqtt_worker | MQTT Worker | — | all, chatbot |
