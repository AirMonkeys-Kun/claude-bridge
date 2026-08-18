import json, socket, statistics, sys, time
HOST = "172.16.10.254"
PORT = 19850

def send_tcp(cmd, timeout=10):
    s = socket.socket()
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    try:
        s.sendall((json.dumps(cmd) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(8192)
            if not chunk: break
            buf += chunk
        return json.loads(buf.decode("utf-8").strip())
    finally:
        try: s.close()
        except OSError: pass

print(f"=== Step 1: ping {HOST}:{PORT} ===")
try:
    pong = send_tcp({"type": "ping"})
    print(f"  workers_alive={pong.get('workers_alive')} watcher={pong.get('watcher_alive')} pipe_mode={pong.get('pipe_mode')}")
except Exception as e:
    print(f"  PING FAILED: {e}"); sys.exit(1)

print("\n=== Step 2: single type=wsl functional test ===")
cmd = {"cmd_id":"wsl_pool_func","command":"echo WSL_POOL_OK; whoami; uname -sr","type":"wsl","timeout":10}
try:
    r = send_tcp(cmd)
    print(f"  channel={r.get('dispatch_channel','?')}")
    print(f"  exit_code={r.get('exit_code')}")
    print(f"  duration_ms={r.get('duration_ms')}")
    print(f"  stdout={r.get('stdout','').strip()!r}")
    print(f"  error={r.get('error','')!r}")
except Exception as e:
    print(f"  FAILED: {e}"); sys.exit(1)

print("\n=== Step 3: latency benchmark (5 iters, echo PROBE) ===")
results = []
for i in range(5):
    cmd = {"cmd_id":f"wsl_pool_bench_{i+1}","command":"echo PROBE","type":"wsl","timeout":10}
    t0 = time.monotonic()
    try:
        r = send_tcp(cmd)
        total_ms = (time.monotonic() - t0) * 1000
        wm = r.get("duration_ms", -1)
        ch = r.get("dispatch_channel", "?")
        results.append({"worker_ms": wm, "total_ms": total_ms})
        print(f"  iter {i+1}: worker={wm:>4}ms total={total_ms:>6.1f}ms channel={ch}")
    except Exception as e:
        print(f"  iter {i+1}: FAILED {e}")
    time.sleep(0.15)

ok = [r for r in results if r["worker_ms"] > 0]
if ok:
    wm = [r["worker_ms"] for r in ok]
    tm = [r["total_ms"] for r in ok]
    print(f"\n  Worker: avg={statistics.mean(wm):.1f}ms min={min(wm)} max={max(wm)}")
    print(f"  Total:  avg={statistics.mean(tm):.1f}ms min={min(tm):.1f} max={max(tm):.1f}")
    print(f"  [Baseline] subprocess fallback: worker avg=114ms (TCP), 146ms (queue.txt)")
