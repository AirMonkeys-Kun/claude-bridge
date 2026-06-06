"""bridge_batch.py — Submit multiple commands to bridge and wait for all results.

Usage:
  python3 bridge_batch.py submit_and_wait <json_file> [timeout]
  python3 bridge_batch.py submit_only <json_file>
  python3 bridge_batch.py wait_only <cmd_id1> <cmd_id2> ... [timeout]

Where json_file contains a JSON array:
  [
    {"cmd_id": "job1", "command": "echo hello", "type": "process", "timeout": 10},
    {"cmd_id": "job2", "command": "Get-Date", "type": "powershell", "timeout": 10}
  ]"""

import sys, os, time, json

BASE = os.path.dirname(os.path.abspath(__file__))
QUEUE = os.path.join(BASE, "queue.txt")
IDLE = '{"state":"idle","cmd_id":"","command":"","type":""}'


def write_queue(payload):
    with open(QUEUE, "w", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False))


def read_queue():
    try:
        with open(QUEUE, "r", encoding="utf-8") as f:
            return json.loads(f.read())
    except Exception:
        return {"state": "error"}


def submit_commands(commands):
    """Submit commands one by one. After each pickup, waits 300ms for watcher to fully cycle."""
    for i, cmd in enumerate(commands):
        cid = cmd.get("cmd_id", "job_" + str(i))
        payload = {
            "state": "pending",
            "cmd_id": cid,
            "command": cmd["command"],
            "type": cmd.get("type", "powershell"),
            "timeout": cmd.get("timeout", 60)
        }
        write_queue(payload)

        start = time.monotonic()
        picked = False
        while time.monotonic() - start < 5:
            q = read_queue()
            if q.get("state") != "pending" or q.get("cmd_id") != cid:
                picked = True
                break
            time.sleep(0.05)

        elapsed = round((time.monotonic() - start) * 1000)
        if picked:
            print(json.dumps({"submitted": cid, "ms": elapsed}))
            # 300ms grace: watcher needs time to dispatch + write result
            time.sleep(0.3)
        else:
            print(json.dumps({"failed_submit": cid, "error": "watcher not picking up"}))


def wait_results(cmd_ids, timeout=120):
    """Poll all result files simultaneously, 100ms interval."""
    result_files = {}
    for cid in cmd_ids:
        result_files[cid] = os.path.join(BASE, "r_" + cid + ".json")

    completed = {}
    failed = set()
    start = time.monotonic()

    while time.monotonic() - start < timeout:
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
                    elapsed = round((time.monotonic() - start) * 1000)
                    print(json.dumps({
                        "cmd_id": cid,
                        "elapsed_ms": elapsed,
                        "result": data
                    }, ensure_ascii=False))
                except Exception as e:
                    failed.add(cid)
                    print(json.dumps({"cmd_id": cid, "error": str(e)}), file=sys.stderr)
            else:
                still_pending.append(cid)

        if not still_pending:
            break
        time.sleep(0.1)

    total = len(cmd_ids)
    ok_count = len(completed)
    fail_count = len(failed)
    timeout_count = total - ok_count - fail_count
    elapsed = round((time.monotonic() - start) * 1000)

    summary = {
        "status": "done" if timeout_count == 0 else "partial",
        "total": total,
        "completed": ok_count,
        "failed": fail_count,
        "timeout": timeout_count,
        "elapsed_ms": elapsed
    }
    print(json.dumps({"summary": summary}, indent=2))
    return timeout_count == 0


def load_commands(json_path):
    with open(json_path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    if len(sys.argv) < 3:
        print("Usage: bridge_batch.py <submit_and_wait|submit_only|wait_only> <json_file|cmd_ids...> [timeout]")
        sys.exit(1)

    action = sys.argv[1]

    if action == "submit_and_wait":
        commands = load_commands(sys.argv[2])
        submit_commands(commands)
        cmd_ids = [c.get("cmd_id", "job_" + str(i)) for i, c in enumerate(commands)]
        timeout = 120
        if len(sys.argv) > 3 and sys.argv[-1].isdigit():
            timeout = int(sys.argv[-1])
        ok = wait_results(cmd_ids, timeout)
        sys.exit(0 if ok else 1)

    elif action == "submit_only":
        commands = load_commands(sys.argv[2])
        submit_commands(commands)

    elif action == "wait_only":
        cmd_ids = sys.argv[2:]
        timeout = 120
        if cmd_ids and cmd_ids[-1].isdigit():
            timeout = int(cmd_ids.pop())
        ok = wait_results(cmd_ids, timeout)
        sys.exit(0 if ok else 1)

    else:
        print("Unknown action: " + action, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
