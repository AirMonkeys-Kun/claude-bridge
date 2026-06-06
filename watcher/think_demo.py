"""think_demo.py - Trigger a thinking request through proxy, observe UI feedback timing."""
import urllib.request, json, time

body = json.dumps({
    "model": "claude-sonnet-4-6",
    "max_tokens": 512,
    "stream": True,
    "thinking": {"type": "enabled", "budget_tokens": 8000},
    "messages": [{"role": "user", "content": "Think carefully step by step. What is the sum of all prime numbers less than 100? Show detailed reasoning."}]
})

req = urllib.request.Request(
    "http://127.0.0.1:4000/v1/messages",
    data=body.encode("utf-8"),
    headers={"Content-Type": "application/json", "x-api-key": "test", "anthropic-version": "2023-06-01"},
    method="POST"
)

print("Sending thinking request to proxy...")
t0 = time.monotonic()
resp = urllib.request.urlopen(req, timeout=120)
t_connected = time.monotonic()

first_think = None
first_content = None
think_count = 0
content_count = 0

for raw_line in resp:
    line = raw_line.decode("utf-8", errors="replace").strip()
    if not line.startswith("data: ") or line == "data: [DONE]":
        continue

    now = time.monotonic()
    elapsed = round((now - t0) * 1000)

    if "thinking_delta" in line:
        think_count += 1
        if first_think is None:
            first_think = elapsed
            print(f"  [{elapsed}ms] FIRST thinking_delta received")

    if "text_delta" in line:
        content_count += 1
        if first_content is None:
            first_content = elapsed
            print(f"  [{elapsed}ms] FIRST text_delta received (content appearing!)")

    if "content_block_start" in line and "tool_use" in line:
        print(f"  [{elapsed}ms] tool_use block started")

t_end = time.monotonic()
total = round((t_end - t0) * 1000)

print(f"\n=== RESULT ===")
print(f"Connect: {round((t_connected - t0) * 1000)}ms")
print(f"First thinking token: {first_think}ms")
print(f"First content token: {first_content}ms")
print(f"Total: {total}ms")
print(f"Thinking events: {think_count}")
print(f"Content events: {content_count}")
