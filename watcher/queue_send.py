#!/usr/bin/env python3
"""
Bridge Queue Writer — reliably writes valid JSON commands to queue.txt.
Usage:
  python3 queue_send.py --id <cmd_id> --cmd "<command>" [--type cmd|powershell] [--timeout 15] [--wait]
"""
import json, os, sys, time, argparse

def write_queue(queue_path, cmd_id, command, cmd_type="cmd", timeout=15):
    data = {
        "state": "pending",
        "cmd_id": cmd_id,
        "command": command,
        "type": cmd_type,
        "timeout": timeout
    }
    with open(queue_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    return True

def wait_result(result_dir, cmd_id, max_wait=30):
    result_path = os.path.join(result_dir, f"r_{cmd_id}.json")
    for i in range(max_wait * 20):
        time.sleep(0.05)
        if os.path.exists(result_path):
            with open(result_path, "r") as f:
                return json.load(f)
    return {"error": "timeout"}

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--id", required=True, help="Command ID")
    p.add_argument("--cmd", required=True, help="Command to execute")
    p.add_argument("--type", default="powershell_text", choices=["cmd","powershell","powershell_text"])
    p.add_argument("--timeout", type=int, default=15)
    p.add_argument("--wait", action="store_true", help="Wait for result")
    p.add_argument("--queue", default=None, help="Queue file path")
    args = p.parse_args()
    if args.queue:
        queue_path = args.queue
    else:
        queue_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "queue.txt")
    write_queue(queue_path, args.id, args.cmd, args.type, args.timeout)
    print(f"Queued: {args.id} (type={args.type})")
    if args.wait:
        result_dir = os.path.dirname(queue_path)
        result = wait_result(result_dir, args.id)
        print(f"Result: {json.dumps(result, ensure_ascii=False)}")
