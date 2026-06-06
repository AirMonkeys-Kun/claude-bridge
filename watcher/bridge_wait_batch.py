"""bridge_wait_batch.py — Poll for multiple bridge results simultaneously.
Usage: python3 bridge_wait_batch.py <cmd_id1> <cmd_id2> ... [timeout_sec]

Single process monitors all result files at once (100ms poll).
Outputs each result as it completes. Exits 0 when all done, 1 on any timeout.

Much more efficient than running bridge_wait.py N times in parallel."""

import sys, os, time, json, select

cmd_ids = list(sys.argv[1:])
timeout = 120

# Check if last arg is a number (timeout)
if cmd_ids and cmd_ids[-1].isdigit():
    timeout = int(cmd_ids.pop())

if not cmd_ids:
    print("Usage: bridge_wait_batch.py <cmd_id1> [cmd_id2...] [timeout_sec]", file=sys.stderr)
    sys.exit(1)

base = os.path.dirname(os.path.abspath(__file__))
result_files = {cid: os.path.join(base, f"r_{cid}.json") for cid in cmd_ids}

start = time.monotonic()
completed = {}
failed = set()

while time.monotonic() - start < timeout:
    # Check all pending result files
    still_pending = []
    for cid in cmd_ids:
        if cid in completed or cid in failed:
            continue
        path = result_files[cid]
        if os.path.exists(path):
            time.sleep(0.05)  # 50ms flush grace
            try:
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                completed[cid] = data
                # Print immediately as it arrives
                print(json.dumps({"cmd_id": cid, "result": data}, ensure_ascii=False, indent=2))
            except Exception as e:
                failed.add(cid)
                print(json.dumps({"cmd_id": cid, "error": str(e)}), file=sys.stderr)
        else:
            still_pending.append(cid)

    # All done?
    if not still_pending:
        break

    time.sleep(0.1)

# Final status
total = len(cmd_ids)
ok = len(completed)
fail = len(failed)
timeout_count = total - ok - fail

summary = {
    "status": "done" if timeout_count == 0 else "partial",
    "total": total,
    "completed": ok,
    "failed": fail,
    "timeout": timeout_count,
    "elapsed_ms": round((time.monotonic() - start) * 1000)
}
print(json.dumps({"summary": summary}, indent=2))
sys.exit(0 if timeout_count == 0 else 1)
