# Profile 环境切换系统

## 作用

允许 bot_runner 和 mqtt_worker 在 **本地 Mosquitto** 和 **AWS IoT Core（云端）** 之间切换 MQTT 连接，无需手动修改环境变量。

## Profile 定义（server.py）

```python
_PROFILE_GROUPS = {
    "mqtt": {
        "available": {
            "local": {
                "name": "本地 Mosquitto",
                "description": "127.0.0.1:1883",
                "env": {
                    "CHATBOT_MQTT_HOST": "127.0.0.1",
                    "CHATBOT_MQTT_PORT": "1883",
                    "CHATBOT_MQTT_ENV": "prod",
                }
            },
            "cloud": {
                "name": "AWS IoT Core",
                "description": "eu-west-2:8883 TLS",
                "env": {
                    "CHATBOT_MQTT_HOST": "AWS IoT Core 端点",
                    "CHATBOT_MQTT_PORT": "8883",
                    "CHATBOT_MQTT_ENV": "production",
                    "AWS_IOT_CERT": "/path/to/cert.pem",
                    "AWS_IOT_KEY": "/path/to/private.pem.key",
                    "AWS_IOT_CA": "/path/to/Amazon-root-CA-1.pem",
                }
            }
        }
    }
}
```

## Profile 切换流程

1. 用户在 ServiceManager 面板点击 "cloud" 或 "local"
2. 前端 POST `/api/services/{id}/profiles` 携带 `{"group": "mqtt", "profile": "cloud"}`
3. 后端更新 `/tmp/start-local-dev/service_profiles.json`
4. 后端停止并重启 bot_runner + mqtt_worker（或所属套件）
5. `_run_svc_script()` 从 profiles 文件读取配置，注入环境变量到子进程

## 存储

```
/tmp/start-local-dev/service_profiles.json
```

```json
{"mqtt": "local"}
```

## 适用范围

| 服务 | 受 profile 影响的环境变量 |
|------|--------------------------|
| bot_runner | CHATBOT_MQTT_HOST, CHATBOT_MQTT_PORT, CHATBOT_MQTT_ENV |
| mqtt_worker | CHATBOT_MQTT_HOST, CHATBOT_MQTT_PORT, CHATBOT_MQTT_ENV, AWS_IOT_CERT, AWS_IOT_KEY, AWS_IOT_CA |

## 架构图

```
ServiceManager.vue                     server.py
┌─────────────┐   POST /profiles     ┌──────────────────┐
│ [local]      │ ──────────────────→ │  更新 profile    │
│ [cloud]      │                     │  JSON 文件        │
└─────────────┘                      │  停止关联服务      │
                                     │  启动关联服务      │
                                     │  (注入 env vars)  │
                                     └──────────────────┘
                                              │
                                     ┌────────▼────────┐
                                     │ service_profiles │
                                     │ .json           │
                                     └─────────────────┘
                                              │
                                     ┌────────▼────────┐
                                     │ start-local-dev  │
                                     │ .sh              │
                                     │ (读取 env vars)  │
                                     └─────────────────┘
