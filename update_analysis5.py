#!/usr/bin/env python3
"""Append section 5 (simulation race condition analysis) to the analysis doc."""
import re

path = '/home/administrator/projects/resonova/docs/38-chain-breakdown-analysis.md'
with open(path) as f:
    content = f.read()

section5 = """

## 问题 5: Session/Turn 双层架构的竞态条件

### 现象

`POST /device/start-session` + `POST /device/simulate` 的两步 API 调用之间存在竞态窗口：

1. `start_session_and_await_intro()` 先启动 session 并等待开场白结束
2. `start_device_simulation()` 检查到设备已连接且有活跃 session → 走 `send_user_turn()` 路径
3. `send_user_turn()` 调用 `DeviceFirmware.start_turn()` 直接发送用户音频

理论竞态窗口：开场白 EOS 到达与用户音频发送之间，bot 侧的状态机可能未完成转换。

### 根因

**架构层面**：存在两条路径可以产生完整通话，它们共享同一个 `DeviceFirmware` 实例：

| 路径 | API | 调用方法 | 行为 |
|------|-----|----------|------|
| 旧路径 (单步) | `POST /device/simulate` (无前序 connect) | `start_simulation()` → `run_session()` | 内部完成 `start_session → wait_intro → start_turn → wait_response → stop_session` |
| 新路径 (两步) | `POST /device/start-session` + `POST /device/simulate` (已 connect) | `start_session_and_await_intro()` → `send_user_turn()` | 分两步，session 保持活性 |

**具体竞态条件**：

1. `start_session_and_await_intro()`（`mqtt_bridge.py:684`）:
   - 调用 `self._fw.start_session()` → 发布 `session/{id}/start` MQTT 消息
   - 调用 `self._fw.wait_for_intro_completion(timeout=30)` → 50ms 间隔轮询 `_intro_eos_event`
   - 收到 EOS 后设置 `_simulating = False`

2. `send_user_turn()`（`mqtt_bridge.py:753`）:
   - 检查 `self._fw.session_id` → 有效则继续
   - 调用 `self._fw.start_turn(pcm_data)` → 发布音频 chunk 到 MQTT
   - 调用 `self._fw.wait_for_turn_response(turn_id, timeout=90, expect_downstream=True)`

**关键竞态点**：`wait_for_turn_response()` 的 `expect_downstream=True` 分支要求 `tracker.downstream_started` 为 True 且 `tracker.eos_event` 被 set。`downstream_started` 由 MQTT 回调设置，回调订阅在 `DeviceFirmware` 构造时建立（`_setup_mqtt_callbacks()`）。如果 bot 侧开场白结束后未能及时建立回复 topic 的订阅，turn 的 downstream 事件可能不被触发。

### 实际验证

本轮测试实际运行了完整链路：
- `POST /device/connect` → OK (intro auto_triggered)
- `POST /device/start-session` → OK (intro_completed: true, session=CprKlt3-2w7p)
- `POST /device/simulate` → TTS response 收到: "What would you like to learn about medicine today?"

**竞态条件未实际命中**，因为:
1. `wait_for_intro_completion()` 的 50ms 轮询足够快
2. `start_turn()` 的 MQTT publish 在 turn 级别操作，不依赖 session 级别的状态同步
3. Bot 侧 `MQTTInputTransport` 按 device_id + session_id 路由消息，intro 和 user turn 的处理路径分离

### 更实际的阻塞点: VAD

虽然链路不崩，但本次测试 STT 为空 (`stt_text: ""`, `stt_confidence: 0.0`)，说明 VAD 仍然阻止了语音识别。这是比竞态条件更优先的 P0 阻塞项。

### 变更文件

无需变更 — 当前架构在正常情况下是安全的。竞态条件是理论的，非实际阻塞。

---

"""

old_lessons = '## 经验教训'
# Find the last existing section before 经验教训
# Current sections: 1 (intro), 2 (VAD), 3 (user_context_processor), 4 (double-emit)
# Insert section 5 before 经验教训

if section5.strip() in content:
    print('ALREADY EXISTS')
else:
    if old_lessons in content:
        content = content.replace(old_lessons, section5 + old_lessons, 1)
        with open(path, 'w') as f:
            f.write(content)
        print('SECTION 5 ADDED OK')
    else:
        print('PATTERN NOT FOUND — appending to end')
        with open(path, 'a') as f:
            f.write(section5)
        print('APPENDED OK')
