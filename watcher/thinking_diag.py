"""thinking_diag.py — Compare thinking token arrival pattern: direct vs proxy.
Records per-event timestamps to distinguish model thinking time from network delay."""

import time, json, sys, os

# Read API key
env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "claude-desktop-config", "proxy", ".env")
api_key = ""
for line in open(env_path, encoding="utf-8"):
    line = line.strip()
    if line.startswith("XIAOMI_API_KEY="):
        api_key = line.split("=", 1)[1].strip()
        break

# Use a prompt that triggers thinking
THINK_PROMPT = "Think step by step: what is 17 * 23 + 45 - 12? Show your reasoning."

DIRECT_BODY = json.dumps({
    "model": "mimo-v2.5-pro",
    "max_tokens": 1024,
    "stream": True,
    "thinking": {"type": "enabled", "budget_tokens": 5000},
    "messages": [{"role": "user", "content": THINK_PROMPT}]
})

PROXY_BODY = json.dumps({
    "model": "claude-sonnet-4-6",
    "max_tokens": 1024,
    "stream": True,
    "thinking": {"type": "enabled", "budget_tokens": 5000},
    "messages": [{"role": "user", "content": THINK_PROMPT}]
})

import urllib.request, ssl
ctx = ssl.create_default_context()


def stream_and_record(url, body, headers, label):
    """Stream SSE and record per-event timestamps."""
    req = urllib.request.Request(url, data=body.encode("utf-8"), headers=headers, method="POST")
    t0 = time.monotonic()
    events = []
    thinking_tokens = 0
    content_tokens = 0
    try:
        resp = urllib.request.urlopen(req, timeout=120, context=ctx if url.startswith("https") else None)
        t_connected = time.monotonic()

        for raw_line in resp:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line.startswith("data: "):
                continue
            data_str = line[6:].strip()
            if data_str == "[DONE]":
                break
            try:
                event = json.loads(data_str)
            except json.JSONDecodeError:
                continue

            now = time.monotonic()
            etype = event.get("type", "")

            if etype == "content_block_delta":
                delta = event.get("delta", {})
                dt = delta.get("type", "")
                if dt == "thinking_delta":
                    t_text = delta.get("thinking", "")
                    thinking_tokens += len(t_text) // 4
                    events.append({
                        "t": round((now - t0) * 1000),
                        "type": "thinking",
                        "chars": len(t_text),
                        "tok": len(t_text) // 4,
                    })
                elif dt == "text_delta":
                    t_text = delta.get("text", "")
                    content_tokens += len(t_text) // 4
                    events.append({
                        "t": round((now - t0) * 1000),
                        "type": "content",
                        "chars": len(t_text),
                        "tok": len(t_text) // 4,
                    })
            elif etype == "content_block_start":
                cb = event.get("content_block", {})
                events.append({
                    "t": round((now - t0) * 1000),
                    "type": "block_start",
                    "block_type": cb.get("type", ""),
                })
            elif etype == "content_block_stop":
                events.append({
                    "t": round((now - t0) * 1000),
                    "type": "block_stop",
                })

        t_end = time.monotonic()

        # Find thinking phase boundaries
        think_events = [e for e in events if e["type"] == "thinking"]
        content_events = [e for e in events if e["type"] == "content"]

        first_think = think_events[0]["t"] if think_events else -1
        last_think = think_events[-1]["t"] if think_events else -1
        first_content = content_events[0]["t"] if content_events else -1

        return {
            "label": label,
            "ok": True,
            "connect_ms": round((t_connected - t0) * 1000),
            "total_ms": round((t_end - t0) * 1000),
            "thinking_tokens": thinking_tokens,
            "content_tokens": content_tokens,
            "think_event_count": len(think_events),
            "content_event_count": len(content_events),
            "first_think_ms": first_think,
            "last_think_ms": last_think,
            "first_content_ms": first_content,
            "think_duration_ms": (last_think - first_think) if first_think >= 0 and last_think >= 0 else 0,
            "events": events,  # full timeline
        }
    except Exception as e:
        return {"label": label, "ok": False, "error": str(e), "total_ms": round((time.monotonic() - t0) * 1000)}


def analyze_gap_pattern(events, event_type="thinking"):
    """Analyze gaps between consecutive events of the same type."""
    filtered = [e for e in events if e["type"] == event_type]
    if len(filtered) < 2:
        return {"count": len(filtered), "gaps": []}
    gaps = []
    for i in range(1, len(filtered)):
        gap = filtered[i]["t"] - filtered[i-1]["t"]
        gaps.append(gap)
    return {
        "count": len(filtered),
        "min_gap_ms": min(gaps),
        "max_gap_ms": max(gaps),
        "avg_gap_ms": round(sum(gaps) / len(gaps)),
        "median_gap_ms": sorted(gaps)[len(gaps)//2],
        "gaps_gt_500ms": sum(1 for g in gaps if g > 500),
        "gaps_gt_1000ms": sum(1 for g in gaps if g > 1000),
        "sample_gaps": gaps[:20],  # first 20 gaps
    }


def run():
    print("=" * 70)
    print("THINKING TOKEN DELIVERY DIAGNOSTIC")
    print("=" * 70)

    # Test 1: Direct backend
    print("\n### TEST 1: Direct backend streaming (with thinking)")
    direct_headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "anthropic-version": "2023-06-01",
    }
    direct = stream_and_record(
        "https://token-plan-cn.xiaomimimo.com/anthropic/v1/messages",
        DIRECT_BODY, direct_headers, "DIRECT"
    )

    if direct["ok"]:
        print(f"  connect={direct['connect_ms']}ms  total={direct['total_ms']}ms")
        print(f"  thinking_tok={direct['thinking_tokens']}  content_tok={direct['content_tokens']}")
        print(f"  think_events={direct['think_event_count']}  content_events={direct['content_event_count']}")
        print(f"  first_think={direct['first_think_ms']}ms  last_think={direct['last_think_ms']}ms")
        print(f"  think_duration={direct['think_duration_ms']}ms")
        think_gaps = analyze_gap_pattern(direct["events"], "thinking")
        print(f"  thinking gaps: {json.dumps(think_gaps, indent=2)}")
    else:
        print(f"  FAILED: {direct.get('error')}")

    time.sleep(2)

    # Test 2: Through proxy
    print("\n### TEST 2: Proxy streaming (with thinking)")
    proxy_headers = {
        "Content-Type": "application/json",
        "x-api-key": "test",
        "anthropic-version": "2023-06-01",
    }
    proxy = stream_and_record(
        "http://127.0.0.1:4000/v1/messages",
        PROXY_BODY, proxy_headers, "PROXY"
    )

    if proxy["ok"]:
        print(f"  connect={proxy['connect_ms']}ms  total={proxy['total_ms']}ms")
        print(f"  thinking_tok={proxy['thinking_tokens']}  content_tok={proxy['content_tokens']}")
        print(f"  think_events={proxy['think_event_count']}  content_events={proxy['content_event_count']}")
        print(f"  first_think={proxy['first_think_ms']}ms  last_think={proxy['last_think_ms']}ms")
        print(f"  think_duration={proxy['think_duration_ms']}ms")
        think_gaps = analyze_gap_pattern(proxy["events"], "thinking")
        print(f"  thinking gaps: {json.dumps(think_gaps, indent=2)}")
    else:
        print(f"  FAILED: {proxy.get('error')}")

    # --- Comparison ---
    print("\n" + "=" * 70)
    print("COMPARISON")
    print("=" * 70)
    if direct["ok"] and proxy["ok"]:
        print(f"\n  {'Metric':<25} {'Direct':>10} {'Proxy':>10} {'Diff':>10}")
        print(f"  {'-'*25} {'-'*10} {'-'*10} {'-'*10}")
        for key in ["connect_ms", "total_ms", "thinking_tokens", "think_event_count",
                     "first_think_ms", "think_duration_ms"]:
            d = direct.get(key, 0)
            p = proxy.get(key, 0)
            diff = p - d if isinstance(d, (int, float)) and isinstance(p, (int, float)) else "N/A"
            print(f"  {key:<25} {d:>10} {p:>10} {diff:>10}")

        # Key metric: is proxy think_duration >> direct think_duration?
        d_dur = direct.get("think_duration_ms", 0)
        p_dur = proxy.get("think_duration_ms", 0)
        if d_dur > 0:
            ratio = p_dur / d_dur
            print(f"\n  think_duration ratio (proxy/direct): {ratio:.2f}x")
            if ratio > 1.5:
                print("  ⚠  Proxy thinking duration significantly longer than direct — possible network delay!")
            elif ratio > 1.2:
                print("  ⚡ Proxy slightly slower — minor overhead, acceptable")
            else:
                print("  ✓  Similar timing — thinking time is model-side, not network")

        # Gap analysis comparison
        d_gaps = analyze_gap_pattern(direct["events"], "thinking")
        p_gaps = analyze_gap_pattern(proxy["events"], "thinking")
        print(f"\n  Direct thinking gap: avg={d_gaps.get('avg_gap_ms',0)}ms  max={d_gaps.get('max_gap_ms',0)}ms  >500ms:{d_gaps.get('gaps_gt_500ms',0)}  >1s:{d_gaps.get('gaps_gt_1000ms',0)}")
        print(f"  Proxy  thinking gap: avg={p_gaps.get('avg_gap_ms',0)}ms  max={p_gaps.get('max_gap_ms',0)}ms  >500ms:{p_gaps.get('gaps_gt_500ms',0)}  >1s:{p_gaps.get('gaps_gt_1000ms',0)}")


if __name__ == "__main__":
    run()
