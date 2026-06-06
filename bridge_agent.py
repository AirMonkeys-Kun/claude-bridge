#!/usr/bin/env python3
"""
bridge_agent.py — TCP gateway for Claude Bridge (Phase 1)

Listens on TCP port 19850. Receives commands from the Cowork sandbox,
writes them to watcher's queue.txt, polls for results, returns via TCP.

This is Phase 1: reuses the existing queue.txt → watcher → worker pipeline.
Zero changes to watcher.ps1 or workers.

Usage:
    python bridge_agent.py [--port 19850] [--watcher-dir D:\\zebbingo\\tools\\claude-bridge\\watcher]

Protocol:
    Request:  {"cmd_id":"xxx","command":"echo hi","type":"powershell","timeout":30}\n
    Response: {"state":"done","cmd_id":"xxx","exit_code":0,"stdout":"hi\\r\\n",...}\n
    Ping:     {"type":"ping"}\n
    Pong:     {"type":"pong","workers":14,"inflight":0}\n
"""

import json
import os
import socket
import struct
import sys
import threading
import time
import uuid
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────

DEFAULT_PORT = 19850
DEFAULT_WATCHER_DIR = r"D:\zebbingo\tools\claude-bridge\watcher"

# Where queue.txt and result files live
WATCHER_DIR = Path(os.environ.get("BRIDGE_WATCHER_DIR", DEFAULT_WATCHER_DIR))
QUEUE_FILE = WATCHER_DIR / "queue.txt"
RESULT_DIR = WATCHER_DIR  # r_{cmd_id}.json is written here

# Timing
POLL_INTERVAL = 0.05        # 50ms between result file checks
QUEUE_WRITE_RETRIES = 3
QUEUE_WRITE_BACKOFF = 0.1   # 100ms between retries
MAX_CONCURRENT = 5          # max simultaneous connections

# Lock for queue.txt writes — only one command at a time through the file
queue_lock = threading.Lock()
active_connections = 0
active_lock = threading.Lock()

# ── Helpers ────────────────────────────────────────────────────────────

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    print(f"[{ts}] {msg}", flush=True)


def gen_cmd_id():
    return f"tcp_{uuid.uuid4().hex[:12]}"


def atomic_write_json(path, data):
    """Write JSON atomically with retries (mirrors watcher's Write-Text)."""
    content = json.dumps(data, ensure_ascii=False)
    for attempt in range(QUEUE_WRITE_RETRIES):
        try:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            return True
        except Exception as e:
            if attempt < QUEUE_WRITE_RETRIES - 1:
                time.sleep(QUEUE_WRITE_BACKOFF)
            else:
                log(f"  WRITE FAILED after {QUEUE_WRITE_RETRIES} attempts: {e}")
                return False


def read_json_file(path):
    """Read JSON file, return None on failure."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def wait_for_result(cmd_id, timeout):
    """Poll for r_{cmd_id}.json to appear, return parsed result."""
    result_file = RESULT_DIR / f"r_{cmd_id}.json"
    deadline = time.monotonic() + timeout + 10  # extra 10s grace
    poll_count = 0

    while time.monotonic() < deadline:
        result = read_json_file(result_file)
        if result is not None:
            # Cleanup: remove result file after reading
            try:
                os.unlink(result_file)
            except OSError:
                pass
            return result

        time.sleep(POLL_INTERVAL)
        poll_count += 1
        if poll_count % 200 == 0:  # every ~10s
            elapsed = time.monotonic() - (deadline - timeout - 10)
            log(f"  [{cmd_id}] still waiting... {elapsed:.1f}s elapsed")

    return {
        "state": "error",
        "cmd_id": cmd_id,
        "exit_code": -1,
        "stdout": "",
        "stderr": f"[TIMEOUT after {timeout}s waiting for result]",
        "error": "result_timeout",
        "duration_ms": int(timeout * 1000),
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }


def submit_command(cmd):
    """Write command to queue.txt (holding the queue_lock). Returns cmd_id."""
    cmd_id = cmd.get("cmd_id") or gen_cmd_id()
    cmd["cmd_id"] = cmd_id
    cmd.setdefault("type", "powershell")
    cmd.setdefault("timeout", 30)

    # Build the pending queue entry (same format watcher expects)
    pending = {
        "state": "pending",
        "cmd_id": cmd_id,
        "command": cmd["command"],
        "type": cmd["type"],
        "timeout": cmd.get("timeout", 30),
    }

    with queue_lock:
        if not atomic_write_json(QUEUE_FILE, pending):
            return None, {"state": "error", "cmd_id": cmd_id, "exit_code": -1,
                          "stdout": "", "stderr": "Failed to write queue.txt",
                          "error": "queue_write_failed", "duration_ms": 0,
                          "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")}

    return cmd_id, None


def reset_queue():
    """Reset queue.txt to idle state."""
    idle = {"state": "idle", "cmd_id": "", "command": "", "type": ""}
    atomic_write_json(QUEUE_FILE, idle)


def handle_ping():
    """Return health status."""
    # Count worker pool entries
    pool_file = WATCHER_DIR.parent / "cluster" / ".worker_pool.json"
    pool = read_json_file(pool_file)
    worker_count = len(pool) if isinstance(pool, list) else 0

    # Check if watcher is alive (heartbeat file recent?)
    hb_file = WATCHER_DIR / ".watcher_heartbeat"
    watcher_alive = False
    try:
        mtime = os.path.getmtime(hb_file)
        watcher_alive = (time.time() - mtime) < 120
    except OSError:
        pass

    return {
        "type": "pong",
        "workers": worker_count,
        "watcher_alive": watcher_alive,
        "active_connections": active_connections,
    }


# ── Connection Handler ─────────────────────────────────────────────────

def handle_client(conn, addr):
    """Handle a single TCP client connection."""
    global active_connections
    with active_lock:
        active_connections += 1

    log(f"Connection from {addr} (active: {active_connections})")

    try:
        buf = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk

            # Process complete messages (newline-delimited)
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue

                try:
                    cmd = json.loads(line.decode("utf-8"))
                except (json.JSONDecodeError, UnicodeDecodeError) as e:
                    err = {"state": "error", "exit_code": -1,
                           "stderr": f"Invalid JSON: {e}", "duration_ms": 0}
                    conn.sendall(json.dumps(err, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                # Ping?
                if cmd.get("type") == "ping":
                    resp = handle_ping()
                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                # Regular command
                t0 = time.monotonic()
                cmd_id, err = submit_command(cmd)
                if err:
                    conn.sendall(json.dumps(err, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                log(f"  [{cmd_id}] Submitted: {cmd['command'][:80]}...")

                # Wait for result
                result = wait_for_result(cmd_id, cmd.get("timeout", 30))
                elapsed = (time.monotonic() - t0) * 1000
                result["tcp_rtt_ms"] = int(elapsed)

                resp_bytes = json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n"
                conn.sendall(resp_bytes)

                exit_code = result.get("exit_code", -1)
                status = "OK" if exit_code == 0 else f"ERR({exit_code})"
                log(f"  [{cmd_id}] {status} in {elapsed:.0f}ms "
                    f"(stdout={len(result.get('stdout', ''))}b)")

    except (ConnectionResetError, BrokenPipeError, OSError):
        pass  # client disconnected
    except Exception as e:
        log(f"  ERROR handling {addr}: {e}")
    finally:
        with active_lock:
            active_connections -= 1
        conn.close()
        log(f"Disconnected {addr} (active: {active_connections})")


# ── Main ───────────────────────────────────────────────────────────────

def main():
    port = int(os.environ.get("BRIDGE_PORT", DEFAULT_PORT))

    # Validate watcher directory
    if not QUEUE_FILE.parent.exists():
        log(f"ERROR: Watcher directory not found: {WATCHER_DIR}")
        log(f"  Set BRIDGE_WATCHER_DIR environment variable or pass --watcher-dir")
        sys.exit(1)

    log(f"bridge_agent.py Phase 1 starting")
    log(f"  Listening:   0.0.0.0:{port}")
    log(f"  Queue:       {QUEUE_FILE}")
    log(f"  Results:     {RESULT_DIR}")
    log(f"  Max clients: {MAX_CONCURRENT}")

    # Reset queue to idle on startup
    reset_queue()
    log("  Queue reset to idle")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(MAX_CONCURRENT)

    log(f"Ready — waiting for connections from sandbox (172.16.10.0/24)")

    try:
        while True:
            conn, addr = srv.accept()
            t = threading.Thread(target=handle_client, args=(conn, addr), daemon=True)
            t.start()
    except KeyboardInterrupt:
        log("Shutting down...")
    finally:
        srv.close()


if __name__ == "__main__":
    # Simple arg parsing
    if "--help" in sys.argv:
        print(__doc__)
        sys.exit(0)
    main()
