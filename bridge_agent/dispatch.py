"""
dispatch.py — Named Pipe direct dispatch and queue.txt fallback for bridge_agent.
"""
import json
import os
import time
import uuid
from pathlib import Path

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


# Log file in the project root (not inside bridge_agent/)
LOG_FILE = Path(__file__).resolve().parent.parent / "bridge_agent_stdout.log"


def _rotate_log():
    """Rotate log file at ~1MB to prevent unbounded growth."""
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > 1 * 1024 * 1024:
            bak = LOG_FILE.with_suffix(".log.1")
            if bak.exists():
                bak.unlink()
            LOG_FILE.rename(bak)
    except OSError:
        pass


def _now_str():
    """strftime-free timestamp — works around broken strftime on some Python builds."""
    n = time.localtime()
    return f"{n.tm_year:04d}-{n.tm_mon:02d}-{n.tm_mday:02d} {n.tm_hour:02d}:{n.tm_min:02d}:{n.tm_sec:02d}"

def log(msg):
    ts = _now_str()
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        _rotate_log()
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass  # best-effort file logging


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
        "timestamp": _now_str(),
    }


# ── Named Pipe dispatch ────────────────────────────────────────────────

def dispatch_via_pipe(cmd_id, command, cmd_type, timeout):
    """
    Try dispatching to workers in round-robin order.
    Returns (worker, result_dict_or_None) tuple.
    If pipe response captured, result contains the full execution result.
    If worker accepted but no pipe response, result is None (retry with fallback)."""
    workers = find_all_workers(cmd_type)
    if not workers:
        log(f"  [{cmd_id}] No alive workers for type '{cmd_type}'")
        return None, None

    cmd_json = json.dumps({
        "cmd_id": cmd_id, "command": command,
        "type": cmd_type, "timeout": timeout,
    }, ensure_ascii=False)

    for worker in workers:
        pipe_name = worker.get("pipe", "")
        if not pipe_name:
            continue

        if HAS_WIN32:
            result = _pipe_win32(pipe_name, cmd_json, cmd_id, worker)
        else:
            ok = _pipe_file(pipe_name, cmd_json, cmd_id, worker)
            result = {"state": "done", "cmd_id": cmd_id} if ok else None

        if result is not None:
            return worker, result

    log(f"  [{cmd_id}] All {len(workers)} workers busy for type '{cmd_type}'")
    return None, None


def _pipe_win32(pipe_name, cmd_json, cmd_id, worker):
    """
    CallNamedPipe — transactional send + receive.
    Returns parsed result dict on success, None on failure.
    Dynamic buffer: 4KB → 64KB on ERROR_MORE_DATA.
    """
    pipe_path = f"\\\\.\\pipe\\{pipe_name}"
    data = (cmd_json + "\n").encode("utf-8")

    for buf_size in (PIPE_RESPONSE_BUFFER, 65536):
        try:
            resp = win32pipe.CallNamedPipe(pipe_path, data, buf_size, PIPE_TIMEOUT_MS)
            if resp and len(resp) > 0:
                # Parse JSON from pipe response (worker returns result via $writer.WriteLine)
                raw = resp.decode("utf-8-sig").strip()
                result = json.loads(raw)
                if "state" in result and "cmd_id" in result:
                    log(f"  [{cmd_id}] PIPE -> {worker['id']} OK ({len(resp)}b response)")
                    return result
            # Empty response — treat as success with no output
            return {"state": "done", "cmd_id": cmd_id,
                    "exit_code": 0, "stdout": "", "stderr": "",
                    "error": "", "pipe_direct": True}
        except Exception as e:
            err_str = str(e)
            # ERROR_MORE_DATA (234) — retry with larger buffer
            if "MORE_DATA" in err_str and buf_size < 65536:
                continue
            return None
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


# ── Maintenance lock ──────────────────────────────────────────────────

MAINTENANCE_LOCK = QUEUE_FILE.parent / ".maintenance.lock"


def set_maintenance_lock(reason="no reason given", ttl=1800):
    """Create .maintenance.lock to suppress all autonomous recovery layers."""
    started_at = _now_str()
    lock = {
        "reason": reason,
        "started_at": started_at,
        "ttl": ttl,
        "pid": os.getpid(),
    }
    try:
        with open(MAINTENANCE_LOCK, "w", encoding="utf-8") as f:
            json.dump(lock, f, ensure_ascii=False)
        log(f"[MAINT] Maintenance lock SET (reason={reason}, ttl={ttl}s)")
        return True
    except OSError as e:
        log(f"[MAINT] Failed to set maintenance lock: {e}")
        return False


def clear_maintenance_lock():
    """Remove .maintenance.lock to re-enable autonomous recovery."""
    try:
        if MAINTENANCE_LOCK.exists():
            MAINTENANCE_LOCK.unlink()
            log("[MAINT] Maintenance lock CLEARED")
        return True
    except OSError as e:
        log(f"[MAINT] Failed to clear maintenance lock: {e}")
        return False


def is_maintenance_locked():
    """Check if maintenance lock exists and is valid."""
    try:
        if not MAINTENANCE_LOCK.exists():
            return False
        raw = MAINTENANCE_LOCK.read_text("utf-8")
        lock = json.loads(raw)
        ttl = lock.get("ttl", 1800)
        started = time.mktime(time.strptime(lock["started_at"], "%Y-%m-%d %H:%M:%S"))
        age = time.time() - started
        if age >= ttl:
            MAINTENANCE_LOCK.unlink(missing_ok=True)
            return False
        return True
    except (OSError, json.JSONDecodeError, KeyError, ValueError):
        try:
            MAINTENANCE_LOCK.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def handle_maintenance_command(cmd):
    """Handle a maintenance command: enter/exit/status.
    Accepts dict with keys: action ('enter'|'exit'|'status'), reason, ttl
    """
    action = cmd.get("action", "status")
    if action == "enter":
        reason = cmd.get("reason", "via queue command")
        ttl = cmd.get("ttl", 1800)
        ok = set_maintenance_lock(reason, ttl)
        return {
            "state": "done" if ok else "error",
            "stdout": f"Maintenance lock {'SET' if ok else 'FAILED'} (reason={reason}, ttl={ttl}s)",
            "exit_code": 0 if ok else 1,
        }
    elif action == "exit":
        ok = clear_maintenance_lock()
        return {
            "state": "done" if ok else "error",
            "stdout": f"Maintenance lock {'CLEARED' if ok else 'FAILED to clear'}",
            "exit_code": 0 if ok else 1,
        }
    else:  # status
        locked = is_maintenance_locked()
        status = "locked" if locked else "unlocked"
        return {
            "state": "done",
            "stdout": f"Maintenance lock status: {status}",
            "exit_code": 0,
        }


def reset_queue():
    idle = {"state": "idle", "cmd_id": "", "command": "", "type": ""}
    content = json.dumps(idle, ensure_ascii=False)
    try:
        with open(QUEUE_FILE, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError:
        pass


# ── Unified execute ────────────────────────────────────────────────────

def execute_command(cmd):
    """
    Execute command via Named Pipe (primary) with queue.txt fallback.
    Returns (result_dict, channel_string).

    Special types:
      "maintenance" — set/clear/check maintenance lock (bypassed pipe/queue)

    Channel strings:
      "pipe"       — Named Pipe direct: response via pipe, no file I/O
      "pipe_file"  — Named Pipe sent but file fallback for result (large output)
      "queue"      — queue.txt path (watcher dispatches)
      "direct"     — handled directly (no pipe or queue needed)
    """
    cmd_id = cmd.get("cmd_id") or gen_cmd_id()
    cmd["cmd_id"] = cmd_id
    cmd.setdefault("type", "powershell")
    cmd.setdefault("timeout", 30)

    # ── Special type: maintenance lock management ──
    if cmd.get("type") == "maintenance":
        result = handle_maintenance_command(cmd)
        result["cmd_id"] = cmd_id
        return result, "direct"

    command = cmd["command"]
    cmd_type = cmd["type"]
    timeout = cmd.get("timeout", 30)

    # ── Primary: Named Pipe dispatch with exponential backoff ──────────
    for attempt in range(PIPE_RETRY_ATTEMPTS):
        worker, result = dispatch_via_pipe(cmd_id, command, cmd_type, timeout)
        if result is not None:
            # Result received directly from pipe — no file I/O needed
            elapsed_ms = result.get("duration_ms", 0)
            log(f"  [{cmd_id}] PIPE_DONE via={worker['id']} "
                f"exit={result.get('exit_code', -1)} dur={elapsed_ms}ms")
            return result, "pipe"

        # worker accepted but no response — fall back to result file
        if worker is not None:
            log(f"  [{cmd_id}] PIPE sent to {worker['id']} but no response — file fallback")
            result = wait_for_result(cmd_id, timeout)
            return result, "pipe_file"

        if attempt < PIPE_RETRY_ATTEMPTS - 1:
            backoff = PIPE_RETRY_DELAY * (2 ** attempt)  # 50ms, 100ms, 200ms
            time.sleep(backoff)

    # ── Fallback: queue.txt (serialized write + wait) ─────────────────
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
                "timestamp": _now_str(),
            }
            return err, "failed"

        result = wait_for_result(cmd_id, timeout)
        return result, "queue"


# ── Internal helpers ───────────────────────────────────────────────────

def _read_result(path):
    """Read a result JSON file."""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
