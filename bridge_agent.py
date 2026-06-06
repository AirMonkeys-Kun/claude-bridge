#!/usr/bin/env python3
"""
bridge_agent.py — TCP gateway for Claude Bridge (Phase 1+3)

Listens on TCP port 19850. Receives commands from the Cowork sandbox,
dispatches directly to workers via Named Pipe (Phase 3), with queue.txt
fallback (Phase 1). Returns results via TCP.

Architecture:
    bridge_agent/        — modular package
      config.py         — paths, constants, shared state
      pool.py           — worker pool loading + process detection
      dispatch.py       — pipe dispatch, queue fallback, result polling
    bridge_agent.py     — thin entry point (server + connection handler)

Usage:
    python bridge_agent.py [--port 19850]

Protocol:
    Request:  {"cmd_id":"xxx","command":"echo hi","type":"powershell","timeout":30}\n
    Response: {"state":"done","cmd_id":"xxx","exit_code":0,"stdout":"hi\\r\\n",...}\n
    Ping:     {"type":"ping"}\n
    Pong:     {"type":"pong","workers":14,"inflight":0}\n
"""

import json
import os
import socket
import sys
import time

from bridge_agent.config import (
    DEFAULT_PORT, MAX_CONCURRENT, QUEUE_FILE, WATCHER_DIR,
    active_connections, active_lock,
)
from bridge_agent.pool import load_worker_pool, is_pid_alive
from bridge_agent.dispatch import execute_command, reset_queue, log


# ── Ping handler ───────────────────────────────────────────────────────

def handle_ping():
    """Return system status for health checks."""
    pool = load_worker_pool()
    workers = pool.get("workers", []) if pool else []
    alive = sum(1 for w in workers if is_pid_alive(w["pid"]))

    watcher_alive = False
    hb_file = WATCHER_DIR / ".watcher_heartbeat"
    try:
        mtime = os.path.getmtime(hb_file)
        watcher_alive = (time.time() - mtime) < 120
    except OSError:
        pass

    try:
        import win32pipe
        pipe_mode = True
    except ImportError:
        pipe_mode = False

    return {
        "type": "pong",
        "workers_total": len(workers),
        "workers_alive": alive,
        "watcher_alive": watcher_alive,
        "active_connections": active_connections,
        "pipe_mode": pipe_mode,
    }


# ── Connection handler ─────────────────────────────────────────────────

def handle_client(conn, addr):
    """Handle a single TCP client connection (multiple commands)."""
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

                if cmd.get("type") == "ping":
                    resp = handle_ping()
                    conn.sendall(json.dumps(resp, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                t0 = time.monotonic()
                result, channel = execute_command(cmd)
                elapsed = (time.monotonic() - t0) * 1000
                result["tcp_rtt_ms"] = int(elapsed)
                result["dispatch_channel"] = channel

                conn.sendall(json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n")

                exit_code = result.get("exit_code", -1)
                status = "OK" if exit_code == 0 else f"ERR({exit_code})"
                log(f"  [{result.get('cmd_id','')}] {status} {elapsed:.0f}ms via={channel} "
                    f"(stdout={len(result.get('stdout', ''))}b)")

    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    except Exception as e:
        log(f"  ERROR handling {addr}: {e}")
    finally:
        with active_lock:
            active_connections -= 1
        conn.close()
        log(f"Disconnected {addr} (active: {active_connections})")


# ── Main ───────────────────────────────────────────────────────────────

def main():
    import threading

    port = int(os.environ.get("BRIDGE_PORT", DEFAULT_PORT))

    if not WATCHER_DIR.exists():
        log(f"ERROR: Watcher directory not found: {WATCHER_DIR}")
        sys.exit(1)

    # Load worker pool
    pool = load_worker_pool(force=True)
    alive_count = 0
    if pool and pool.get("workers"):
        alive_count = sum(1 for w in pool["workers"] if is_pid_alive(w["pid"]))

    try:
        import win32pipe
        pipe_mode = "win32pipe"
    except ImportError:
        pipe_mode = "file I/O fallback"

    log(f"bridge_agent.py Phase 1+3 starting")
    log(f"  Listening:     0.0.0.0:{port}")
    log(f"  Worker pool:   {alive_count} alive workers")
    log(f"  Pipe mode:     {pipe_mode}")
    log(f"  Queue fallback: {QUEUE_FILE}")
    log(f"  Max clients:   {MAX_CONCURRENT}")

    reset_queue()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(MAX_CONCURRENT)

    log(f"Ready — Phase 3 (pipe direct) + Phase 1 (queue fallback)")

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
    if "--help" in sys.argv:
        print(__doc__)
        sys.exit(0)
    main()
