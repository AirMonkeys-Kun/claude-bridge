"""
============================================================
 server.py — 服务管理相关代码摘要
 完整文件: D:\zebbingo\projects\stt-test-tool\backend\server.py
============================================================

主要函数:
  _run_svc_script(action, suite)  — 执行 start-local-dev.sh
  _parse_svc_status()             — 解析服务状态
  _svc_start(suite)               — 启动服务套件
  _svc_stop(suite)                — 停止服务套件
  _svc_restart(suite)             — 重启服务套件
  _load_active_profiles()         — 加载 profile 配置
  _save_active_profiles()         — 保存 profile 配置
  _get_active_profile()           — 获取指定组的 profile
  _get_profile_env_vars()         — 获取 profile 的环境变量

API 端点:
  GET  /api/services              → _parse_svc_status()
  POST /api/services/start/{suite} → _svc_start(suite)
  POST /api/services/stop/{suite}  → _svc_stop(suite)
  POST /api/services/restart/{suite} → _svc_restart(suite)
  GET  /api/services/annotations   → 服务描述 + profile 信息
  GET  /api/services/{id}/env      → 服务的环境变量 + 当前值
  POST /api/services/{id}/profiles → 切换 profile + 重启服务

常量:
  _SERVICE_SCRIPT = "/home/administrator/projects/start-local-dev/start-local-dev.sh"
  _VALID_SUITES   = ["all", "chatbot", "stt"]
  _PROFILES_FILE  = "/tmp/start-local-dev/service_profiles.json"
  _SERVICE_PROFILE_GROUP = {"bot_runner": "mqtt", "mqtt_worker": "mqtt"}
  _PROFILE_GROUPS = {
      "mqtt": {
          "available": {
              "local": {"name": "本地 Mosquitto", ...},
              "cloud": {"name": "AWS IoT Core", ...},
          }
      }
  }
  _SERVICE_ANNOTATIONS = {
      "bot_runner": {
          "description": "...",
          "env_vars": [
              {"key": "CHATBOT_MQTT_ENV", "description": "...", ...},
          ]
      }
  }
"""
