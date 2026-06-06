#!/usr/bin/env python3
"""
bridge_agent.py — TCP gateway for Claude Bridge (Phase 1+3)

Listens on TCP port 19850. Receives commands from the Cowork sandbox,
dispatches directly to workers via Named Pipe (Phase 3), with queue.txt
fallback (Phase 1). Returns results via TCP.

Phase 1: write to queue.txt → watcher processes → poll result file
Phase 3: connect to worker Named Pipe directly → poll result file

Usage:
    python bridge_agent.py [--port 19850]

Protocol:
    Request:  {"cmd_id":"xxx","command":"echo hi","type":"powershell","timeout":30}\n
    Response: {"state":"done","cmd_id":"xxx","exit_code":0,"stdout":"hi\\r\\n",...}\n
    Ping:     {"type":"ping"}\n
    Pong:     {"type":"pong","workers":14,"inflight":0}\n
"""

import ctypes
import json
import os
import socket
import sys
import threading
import time
import uuid
from pathlib import Path

try:
    import win32pipe
    import win32file
    HAS_WIN32 = True
except ImportError:
    HAS_WIN32 = False

# ── Helpers (cross-platform) ──────────────────────────────────────────

def is_pid_alive(pid):
    """Check if a process is alive. Works on Windows and Linux."""
    if sys.platform == "win32":
        kernel32 = ctypes.windll.kernel32
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259

        # Must declare types for 64-bit Windows (handles are pointer-sized)
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_bool, ctypes.c_ulong]
        kernel32.GetExitCodeProcess.restype = ctypes.c_bool
        kernel32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel32.CloseHandle.restype = ctypes.c_bool
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]

        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        exit_code = ctypes.c_ulong()
        ok = kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
        kernel32.CloseHandle(handle)
        return ok and exit_code.value == STILL_ACTIVE
    else:
        try:
            os.kill(pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False


# ── Configuration ──────────────────────────────────────────────────────

DEFAULT_PORT = 19850
DEFAULT_WATCHER_DIR = r"D:\zebbingo\tools\claude-bridge\watcher"
DEFAULT_CLUSTER_DIR = r"D:\zebbingo\tools\claude-bridge\cluster"

WATCHER_DIR = Path(os.environ.get("BRIDGE_WATCHER_DIR", DEFAULT_WATCHER_DIR))
CLUSTER_DIR = Path(os.environ.get("BRIDGE_CLUSTER_DIR", DEFAULT_CLUSTER_DIR))
QUEUE_FILE = WATCHER_DIR / "queue.txt"
POOL_FILE = CLUSTER_DIR / ".worker_pool.json"
RESULT_DIR = WATCHER_DIR

# Timing
POLL_INTERVAL = 0.02        # 20ms between result file checks (faster for Phase 3)
QUEUE_WRITE_RETRIES = 3
QUEUE_WRITE_BACKOFF = 0.1
PIPE_CONNECT_TIMEOUT_MS = 2000  # same as watcher
PIPE_ACK_TIMEOUT_MS = 200       # slightly longer than watcher's 100ms
MAX_CONCURRENT = 5

# Global state
queue_lock = threading.Lock()
active_connections = 0
active_lock = threading.Lock()
_worker_pool = None
_pool_load_time = 0
_pool_lock = threading.Lock()

# ── Helpers ────────────────────────────────────────────────────────────

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    print(f"[{ts}] {msg}", flush=True)


def gen_cmd_id():
    return f"tcp_{uuid.uuid4().hex[:12]}"


def atomic_write_json(path, data):
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
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def wait_for_result(cmd_id, timeout):
    result_file = RESULT_DIR / f"r_{cmd_id}.json"
    deadline = time.monotonic() + timeout + 10
    poll_count = 0

    while time.monotonic() < deadline:
        result = read_json_file(result_file)
        if result is not None:
            try:
                os.unlink(result_file)
            except OSError:
                pass
            return result

        time.sleep(POLL_INTERVAL)
        poll_count += 1
        if poll_count % 500 == 0:  # every ~10s
            elapsed = time.monotonic() - (deadline - timeout - 10)
            log(f"  [{cmd_id}] still waiting... {elapsed:.1f}s elapsed")

    return {
        "state": "error", "cmd_id": cmd_id, "exit_code": -1,
        "stdout": "", "stderr": f"[TIMEOUT after {timeout}s waiting for result]",
        "error": "result_timeout", "duration_ms": int(timeout * 1000),
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }


# ── Worker Pool ────────────────────────────────────────────────────────

def load_worker_pool(force=False):
    """Load and cache .worker_pool.json (30s TTL)."""
    global _worker_pool, _pool_load_time
    now = time.monotonic()
    with _pool_lock:
        if not force and _worker_pool and (now - _pool_load_time) < 30:
            return _worker_pool
        pool_data = read_json_file(POOL_FILE)
        if pool_data and "workers" in pool_data:
            _worker_pool = pool_data
            _pool_load_time = now
            return _worker_pool
    return None


def find_worker(cmd_type):
    """Find an alive worker for the given command type. Returns worker dict or None."""
    pool = load_worker_pool()
    if not pool or not pool.get("workers"):
        return None

    # Map command type to worker type (mirrors watcher Get-WorkerForType)
    type_map = {
        "wsl": "wsl", "user": "user", "file": "file",
        "process": "process", "system": "system",
    }
    target = type_map.get(cmd_type, "generic")

    # Filter by type and alive PID
    candidates = [w for w in pool["workers"] if w.get("type") == target]
    if not candidates and target != "generic":
        candidates = [w for w in pool["workers"] if w.get("type") == "generic"]

    if not candidates:
        return None

    # Check PID alive
    for w in candidates:
        if is_pid_alive(w["pid"]):
            return w

    return None


# ── Named Pipe Dispatch (Phase 3) ─────────────────────────────────────

def dispatch_via_pipe(cmd_id, command, cmd_type, timeout):
    """Send command directly to a worker via Named Pipe.
    Returns worker dict on success, None on failure."""

    worker = find_worker(cmd_type)
    if not worker:
        log(f"  [{cmd_id}] No alive worker for type '{cmd_type}'")
        return None

    pipe_name = worker.get("pipe", "")
    if not pipe_name:
        return None

    cmd_json = json.dumps({
        "cmd_id": cmd_id,
        "command": command,
        "type": cmd_type,
        "timeout": timeout,
    }, ensure_ascii=False)

    if HAS_WIN32:
        return _dispatch_win32pipe(pipe_name, cmd_json, cmd_id, worker)
    else:
        return _dispatch_file_pipe(pipe_name, cmd_json, cmd_id, worker)


def _dispatch_win32pipe(pipe_name, cmd_json, cmd_id, worker):
    """Use win32pipe/win32file for Named Pipe communication."""
    try:
        handle = win32pipe.CallNamedPipe(
            f"\\\\.\\pipe\\{pipe_name}",
            (cmd_json + "\n").encode("utf-8"),
            4096,  # max response bytes
            PIPE_CONNECT_TIMEOUT_MS // 1000,  # timeout in seconds
        )
        # CallNamedPipe is synchronous — it sent the data and got a response
        # But our workers don't send the result via pipe, they write to file
        # So we just need to confirm the pipe write succeeded
        log(f"  [{cmd_id}] PIPE → {worker['id']} OK")
        return worker
    except Exception as e:
        log(f"  [{cmd_id}] PIPE → {worker['id']} failed: {e}")
        return None


def _dispatch_file_pipe(pipe_name, cmd_json, cmd_id, worker):
    """Fallback: use Python file I/O on \\.\pipe\... path."""
    pipe_path = f"\\\\.\\pipe\\{pipe_name}"
    try:
        with open(pipe_path, "w+", encoding="utf-8") as f:
            f.write(cmd_json + "\n")
            f.flush()
        log(f"  [{cmd_id}] PIPE(file) → {worker['id']} OK")
        return worker
    except Exception as e:
        log(f"  [{cmd_id}] PIPE(file) → {worker['id']} failed: {e}")
        return None


# ── Submit Command (unified) ───────────────────────────────────────────

def submit_command(cmd):
    """Try Phase 3 (Named Pipe) first, fall back to Phase 1 (queue.txt)."""
    cmd_id = cmd.get("cmd_id") or gen_cmd_id()
    cmd["cmd_id"] = cmd_id
    cmd.setdefault("type", "powershell")
    cmd.setdefault("timeout", 30)

    command = cmd["command"]
    cmd_type = cmd["type"]
    timeout = cmd.get("timeout", 30)

    # Phase 3: try direct Named Pipe dispatch
    worker = dispatch_via_pipe(cmd_id, command, cmd_type, timeout)
    if worker:
        return cmd_id, None, "pipe"

    # Phase 1 fallback: write to queue.txt
    log(f"  [{cmd_id}] Pipe failed, falling back to queue.txt")
    pending = {
        "state": "pending", "cmd_id": cmd_id,
        "command": command, "type": cmd_type, "timeout": timeout,
    }

    with queue_lock:
        if not atomic_write_json(QUEUE_FILE, pending):
            return None, {
                "state": "error", "cmd_id": cmd_id, "exit_code": -1,
                "stdout": "", "stderr": "Failed to write queue.txt",
                "error": "queue_write_failed", "duration_ms": 0,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            }, "failed"

    return cmd_id, None, "queue"


def reset_queue():
    idle = {"state": "idle", "cmd_id": "", "command": "", "type": ""}
    atomic_write_json(QUEUE_FILE, idle)


def handle_ping():
    pool = load_worker_pool()
    worker_count = len(pool.get("workers", [])) if pool else 0

    # Count alive workers
    alive = 0
    if pool and pool.get("workers"):
        for w in pool["workers"]:
            if is_pid_alive(w["pid"]):
                alive += 1

    hb_file = WATCHER_DIR / ".watcher_heartbeat"
    watcher_alive = False
    try:
        mtime = os.path.getmtime(hb_file)
        watcher_alive = (time.time() - mtime) < 120
    except OSError:
        pass

    return {
        "type": "pong",
        "workers_total": worker_count,
        "workers_alive": alive,
        "watcher_alive": watcher_alive,
        "active_connections": active_connections,
        "pipe_mode": HAS_WIN32,
    }


# ── Connection Handler ─────────────────────────────────────────────────

def handle_client(conn, addr):
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
                cmd_id, err, channel = submit_command(cmd)
                if err:
                    conn.sendall(json.dumps(err, ensure_ascii=False).encode("utf-8") + b"\n")
                    continue

                log(f"  [{cmd_id}] via={channel}: {cmd['command'][:60]}...")

                result = wait_for_result(cmd_id, cmd.get("timeout", 30))
                elapsed = (time.monotonic() - t0) * 1000
                result["tcp_rtt_ms"] = int(elapsed)
                result["dispatch_channel"] = channel

                conn.sendall(json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n")

                exit_code = result.get("exit_code", -1)
                status = "OK" if exit_code == 0 else f"ERR({exit_code})"
                log(f"  [{cmd_id}] {status} {elapsed:.0f}ms via={channel} "
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
    port = int(os.environ.get("BRIDGE_PORT", DEFAULT_PORT))

    if not WATCHER_DIR.exists():
        log(f"ERROR: Watcher directory not found: {WATCHER_DIR}")
        sys.exit(1)

    # Load worker pool
    pool = load_worker_pool(force=True)
    alive_count = 0
    if pool and pool.get("workers"):
        for w in pool["workers"]:
            if is_pid_alive(w["pid"]):
                alive_count += 1

    log(f"bridge_agent.py Phase 1+3 starting")
    log(f"  Listening:     0.0.0.0:{port}")
    log(f"  Worker pool:   {alive_count} alive workers")
    log(f"  Pipe mode:     {'win32pipe' if HAS_WIN32 else 'file I/O fallback'}")
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
