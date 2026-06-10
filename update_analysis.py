#!/usr/bin/env python3
"""Append sections 3 (user_context_processor) and 4 (double-emit fix) to analysis doc."""

path = '/home/administrator/projects/resonova/docs/38-chain-breakdown-analysis.md'
with open(path) as f:
    content = f.read()

sections = """

## 问题 3: user_context_processor 未定义导致 LLM pipeline 崩溃

### 现象

启动 session 后，chatbot 在 LLM 处理阶段崩溃，`bot_mqtt.service` 日志报错:
```
NameError: name 'user_context_processor' is not defined
```

### 根因

`bot_mqtt.py` 中 `_reset_session_processors()` 方法通过闭包引用了 `user_context_processor` 和 `assistant_context_processor`，但这两个变量从未被赋值。

`LLMContextAggregatorPair` 构造函数返回 pair 对象后，后续代码没有提取 pair 的两个处理器实例:
```python
# 错误: pair 被创建但 processor 变量没赋值
pair = LLMContextAggregatorPair(...)
# 缺少:
# user_context_processor = pair.user()
# assistant_context_processor = pair.assistant()
```

### 修复

在 `LLMContextAggregatorPair` 构造后立即提取两个 processor:
```python
pair = LLMContextAggregatorPair(
    user_context_aggregator=user_context_aggregator,
    assistant_context_aggregator=assistant_context_aggregator,
    llm=llm,
    tools=[],
)
user_context_processor = pair.user()
assistant_context_processor = pair.assistant()
```

### 验证

全链路测试通过: STT → Moderation → LLM (Studio AI → GPT-4.1-mini) → TTS (MiniMax) → MQTT 音频输出。session 完成 2 轮对话 (开场白 + 用户语音回复)。

---

## 问题 4: reply_text 词汇重复 (OutputModerationGate 双发 bug)

### 现象

TTS 回复文本中每个词出现两次，导致语音输出中有明显的重复/回音感。

### 根因

`OutputModerationGate.process_frame()` 的 `LLMTextFrame` handler 中存在 **两次** `_hook_manager.emit("llm_text", ...)` 调用:

1. **无条件发射** — 在 `isinstance(frame, LLMTextFrame)` 检查之后，`_response_active` 判断之前
2. **条件发射** — 在 `_response_active=True` 时的文本累积过程中

当 `_response_active=True` 时，同一个 `LLMTextFrame` 触发两次 monitoring emit，导致 conversation reply_text 中每个词在监控流中被记录两次，最终 TTS 输出词汇重复。

```python
# 修复前 (简化伪代码):
def process_frame(frame):
    if isinstance(frame, LLMTextFrame):
        # EMIT #1: 无条件
        _hook_manager.emit("llm_text", {"text": frame.text})

        if not self._response_active:
            push_frame(frame)
            return

        self._accumulated_text += frame.text
        # EMIT #2: 重复, 在 _response_active 分支中
        _hook_manager.emit("llm_text", {"text": frame.text})
```

### 修复

删除第二个 emit，只保留 **一个** 无条件发射在 `_response_active` 检查之前:

```python
# 修复后:
def process_frame(frame):
    if isinstance(frame, LLMTextFrame):
        # 仅此一个 emit，无条件的
        if _MONITORING_AVAILABLE and _hook_manager and _hook_manager.is_enabled():
            try:
                _hook_manager.emit("llm_text", {
                    "session_id": self.session_id,
                    "text": frame.text,
                })
            except Exception as _e:
                logger.warning("llm_text hook error", _e)

        if not self._response_active:
            push_frame(frame)
            return

        # 累积文本 (不再重复 emit)
        self._accumulated_text += frame.text
        ...
```

### 验证

全链路测试结果:
- LLM 回复: "That is not a suitable topic for our story. Would you like to explore how doctors learn about the body instead?"
- **无重复词**, TTS 输出 333 KB WAV 文件正常
- 开场白 (Turn 0) 和用户语音回复 (Turn 1) 均通过

### 变更文件

- `/home/administrator/projects/chatbot/src/processors/output_moderation_gate.py`

---

"""

old_lessons = '## 经验教训'
new_content = sections + old_lessons
assert old_lessons in content, "Pattern not found!"
content = content.replace(old_lessons, new_content, 1)

with open(path, 'w') as f:
    f.write(content)

print('UPDATED OK')
