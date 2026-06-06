"""bridge_wait.py — Poll for bridge result file, 100ms granularity.
Usage: python3 bridge_wait.py <cmd_id> [timeout_sec]
Reads r_<cmd_id>.json as soon as it appears, prints content, exits 0.
Timeout exits 1. No fixed sleep guessing."""
import sys, os, time, json

cmd_id = sys.argv[1]
timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 120
base = os.path.dirname(os.path.abspath(__file__))
result_file = os.path.join(base, f"r_{cmd_id}.json")

start = time.monotonic()
while time.monotonic() - start < timeout:
    if os.path.exists(result_file):
        # Give writer a brief moment to flush (9P propagation ~50ms)
        time.sleep(0.05)
        with open(result_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        print(json.dumps(data, ensure_ascii=False, indent=2))
        sys.exit(0)
    time.sleep(0.1)

print(f"TIMEOUT: r_{cmd_id}.json not found after {timeout}s", file=sys.stderr)
sys.exit(1)
