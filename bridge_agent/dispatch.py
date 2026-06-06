"""
dispatch.py — Named Pipe direct dispatch and queue.txt fallback for bridge_agent.
"""
import json
import time
import uuid

from .config import (
    POLL_INTERVAL, QUEUE_WRITE_RETRIES, QUEUE_WRITE_BACKOFF,
    PIPE_RETRY_ATTEMPTS, PIPE_RETRY_DELAY, PIPE_RESPONSE_BUFFER,
    PIPE_TIMEOUT_MS,
    QUEUE_FILE, RESULT_DIR, queue_serial,
)
from .pool import find_all_workers

try:
    import win32pipe
    import win32file
    HAS_WIN32 = True
except ImportError:
    HAS_WIN32 = False


def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    print(f"[{ts}] {msg}", flush=True)


def gen_cmd_id():
    return f"tcp_{uuid.uuid4().hex[:12]}"


# ── Result polling ────────────────────────────────────────────────────

def wait_for_result(cmd_id, timeout):
    """Poll for r_{cmd_id}.json until timeout. Returns result dict."""
    result_file = RESULT_DIR / f"r_{cmd_id}.json"
    deadline = time.monotonic() + timeout + 10
    poll_count = 0

    while time.monotonic() < deadline:
        result = _read_result(result_file)
        if result is not None:
            try:
                os.unlink(result_file)
            except OSError:
                pass
            return result

        time.sleep(POLL_INTERVAL)
        poll_count += 1
        if poll_count % 500 == 0:
            elapsed = time.monotonic() - (deadline - timeout - 10)
            log(f"  [{cmd_id}] still waiting... {elapsed:.1f}s elapsed")

    return {
        "state": "error", "cmd_id": cmd_id, "exit_code": -1,
        "stdout": "", "stderr": f"[TIMEOUT after {timeout}s waiting for result]",
        "error": "result_timeout", "duration_ms": int(timeout * 1000),
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }


# ── Named Pipe dispatch ────────────────────────────────────────────────

def dispatch_via_pipe(cmd_id, command, cmd_type, timeout):
    """Try dispatching to workers in round-robin order.
    Returns worker dict on success, None on failure."""
    workers = find_all_workers(cmd_type)
    if not workers:
        log(f"  [{cmd_id}] No alive workers for type '{cmd_type}'")
        return None

    cmd_json = json.dumps({
        "cmd_id": cmd_id, "command": command,
        "type": cmd_type, "timeout": timeout,
    }, ensure_ascii=False)

    for worker in workers:
        pipe_name = worker.get("pipe", "")
        if not pipe_name:
            continue

        if HAS_WIN32:
            ok = _pipe_win32(pipe_name, cmd_json, cmd_id, worker)
        else:
            ok = _pipe_file(pipe_name, cmd_json, cmd_id, worker)

        if ok:
            return worker

    log(f"  [{cmd_id}] All {len(workers)} workers busy for type '{cmd_type}'")
    return None


def _pipe_win32(pipe_name, cmd_json, cmd_id, worker):
    """win32pipe.CallNamedPipe — returns worker on success."""
    try:
        win32pipe.CallNamedPipe(
            f"\\\\.\\pipe\\{pipe_name}",
            (cmd_json + "\n").encode("utf-8"),
            PIPE_RESPONSE_BUFFER, PIPE_TIMEOUT_MS,
        )
        log(f"  [{cmd_id}] PIPE -> {worker['id']} OK")
        return True
    except Exception:
        return None


def _pipe_file(pipe_name, cmd_json, cmd_id, worker):
    """Fallback: Python file I/O on pipe path."""
    try:
        with open(f"\\\\.\\pipe\\{pipe_name}", "w+", encoding="utf-8") as f:
            f.write(cmd_json + "\n")
            f.flush()
        log(f"  [{cmd_id}] PIPE(file) -> {worker['id']} OK")
        return True
    except Exception as e:
        log(f"  [{cmd_id}] PIPE(file) -> {worker['id']} failed: {e}")
        return None


# ── Queue.txt fallback ─────────────────────────────────────────────────

def _write_queue(cmd):
    """Write a pending command to queue.txt with retries."""
    content = json.dumps(cmd, ensure_ascii=False)
    for attempt in range(QUEUE_WRITE_RETRIES):
        try:
            with open(QUEUE_FILE, "w", encoding="utf-8") as f:
                f.write(content)
            return True
        except Exception as e:
            if attempt < QUEUE_WRITE_RETRIES - 1:
                time.sleep(QUEUE_WRITE_BACKOFF)
            else:
                log(f"  WRITE FAILED after {QUEUE_WRITE_RETRIES} attempts: {e}")
                return False


def reset_queue():
    idle = {"state": "idle", "cmd_id": "", "command": "", "type": ""}
    content = json.dumps(idle, ensure_ascii=False)
    try:
        with open(QUEUE_FILE, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError:
        pass


# ── Unified execute ────────────────────────────────────────────────────

import os

def execute_command(cmd):
    """Try Named Pipe with retries, fall back to queue.txt.
    Returns (result_dict, channel_string)."""
    cmd_id = cmd.get("cmd_id") or gen_cmd_id()
    cmd["cmd_id"] = cmd_id
    cmd.setdefault("type", "powershell")
    cmd.setdefault("timeout", 30)

    command = cmd["command"]
    cmd_type = cmd["type"]
    timeout = cmd.get("timeout", 30)

    # Phase 3: try Named Pipe dispatch with exponential backoff
    # (Phase 4 Step 2: fixed delay → exponential backoff)
    for attempt in range(PIPE_RETRY_ATTEMPTS):
        worker = dispatch_via_pipe(cmd_id, command, cmd_type, timeout)
        if worker:
            log(f"  [{cmd_id}] via=pipe (attempt {attempt+1}): {command[:60]}...")
            result = wait_for_result(cmd_id, timeout)
            return result, "pipe"
        if attempt < PIPE_RETRY_ATTEMPTS - 1:
            backoff = PIPE_RETRY_DELAY * (2 ** attempt)  # exponential: 50ms, 100ms, 200ms
            time.sleep(backoff)

    # Phase 1 fallback: queue.txt (serialized write + wait)
    log(f"  [{cmd_id}] via=queue: {command[:60]}...")
    pending = {
        "state": "pending", "cmd_id": cmd_id,
        "command": command, "type": cmd_type, "timeout": timeout,
    }

    with queue_serial:
        if not _write_queue(pending):
            err = {
                "state": "error", "cmd_id": cmd_id, "exit_code": -1,
                "stdout": "", "stderr": "Failed to write queue.txt",
                "error": "queue_write_failed", "duration_ms": 0,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            }
            return err, "failed"

        result = wait_for_result(cmd_id, timeout)
        return result, "queue"


# ── Internal helpers ───────────────────────────────────────────────────

def _read_result(path):
    """Read a result JSON file."""
    try:
        with open(