"""
test_capture_thinking.py
Send a request through the proxy with various thinking configs and capture the logs.
"""
import urllib.request, json, time, sys, os

def send_test(label, thinking_config):
    body = json.dumps({
        "model": "claude-sonnet-4-6",
        "max_tokens": 256,
        "stream": True,
        "thinking": thinking_config,
        "messages": [{"role": "user", "content": "Say hello in 3 words."}]
    })

    print(f"\n{'='*60}")
    print(f"TEST: {label}")
    print(f"  Sending thinking config: {json.dumps(thinking_config, ensure_ascii=False)}")

    req = urllib.request.Request(
        "http://127.0.0.1:4000/v1/messages",
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/json", "x-api-key": "test", "anthropic-version": "2023-06-01"},
        method="POST"
    )

    try:
        t0 = time.monotonic()
        resp = urllib.request.urlopen(req, timeout=60)

        think_events = 0
        text_events = 0
        sig_events = 0
        block_types = []

        for raw_line in resp:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            try:
                event = json.loads(line[6:])
            except:
                continue

            etype = event.get("type", "")
            if etype == "content_block_start":
                cb = event.get("content_block", {})
                block_types.append(cb.get("type"))
            elif etype == "content_block_delta":
                dt = event.get("delta", {}).get("type", "")
                if dt == "thinking_delta":
                    think_events += 1
                elif dt == "text_delta":
                    text_events += 1
                elif dt == "signature_delta":
                    sig_events += 1

        elapsed = round((time.monotonic() - t0) * 1000)
        print(f"  Status: {resp.status}")
        print(f"  Elapsed: {elapsed}ms")
        print(f"  Block types: {block_types}")
        print(f"  thinking_delta: {think_events}")
        print(f"  text_delta: {text_events}")
        print(f"  signature_delta: {sig_events}")

    except urllib.error.HTTPError as e:
        print(f"  HTTP Error: {e.code} {e.reason}")
        print(f"  Body: {e.read().decode()[:300]}")
    except Exception as e:
        print(f"  ERROR: {e}")


# Test 1: What Claude Desktop actually sends (adaptive only)
send_test("adaptive (Claude Desktop default)", {"type": "adaptive"})

# Test 2: adaptive + display:summarized
send_test("adaptive + display:summarized", {"type": "adaptive", "display": "summarized"})

# Test 3: adaptive + display:omitted
send_test("adaptive + display:omitted", {"type": "adaptive", "display": "omitted"})

# Test 4: adaptive with budget (older style)
send_test("adaptive + budget_tokens", {"type": "adaptive", "budget_tokens": 4096})

# Test 5: enabled (non-adaptive fallback)
send_test("enabled + budget_tokens", {"type": "enabled", "budget_tokens": 2048})

print(f"\n{'='*60}")
print(f"DONE. Now check proxy.log for THINKING_CONFIG lines.")
print(f"Command: Select-String THINKING_CONFIG D:\\zebbingo\\tools\\claude-desktop-config\\proxy\\proxy.log")
