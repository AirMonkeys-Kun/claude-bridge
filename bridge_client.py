#!/usr/bin/env python3
"""
bridge_client.py — TCP client for Claude Bridge (Phase 2)

Connects to bridge_agent.py on the Windows host. Sends commands,
receives results. Falls back to queue.txt file bridge if TCP is unavailable.

Usage from Claude sandbox:
    python3 bridge_client.py '{"command":"echo hello","type":"powershell","timeout":30}'
    python3 bridge_client.py --cmd "echo hello" --type powershell
    python3 bridge_client.py --ping
    python3 bridge_client.py --fallback '{"command":"..."}'  # force file-based mode (--fallback before or after JSON, both work)

Environment:
    BRIDGE_HOST    — bridge_agent IP (default: 172.16.10.254)
    BRIDGE_PORT    — bridge_agent port (default: 19850)
    BRIDGE_DIR     — watcher directory for file fallback
                     (default: /sessions/.../mnt/tools/claude-bridge/watcher)
"""

import json
import os
import socket
import sys
import time
import uuid

# ── Configuration ──────────────────────────────────────────────────────

BRIDGE_HOST = os.environ.get("BRIDGE_HOST", "172.16.10.254")
BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT", "19850"))
TCP_TIMEOUT = 5  # seconds to connect
TCP_FAST_RETRY_MS = int(os.environ.get("BRIDGE_FAST_RETRY_MS", "200"))

# V3.5: Connection pool — reuse one persistent TCP socket across commands.
# bridge_agent supports multiple commands on one connection (while-loop in
# handle_client). A 3-tuple of (socket, reader, lock) cached per process.
_pooled_sock = None
_pooled_reader = None
_pooled_lock = None


def _get_pooled_connection(host=BRIDGE_HOST, port=BRIDGE_PORT):
    """Return (sock, reader) tuple from connection pool, creating if needed."""
    import threading
    global _pooled_sock, _pooled_reader, _pooled_lock
    if _pooled_lock is None:
        _pooled_lock = threading.Lock()

    with _pooled_lock:
        if _pooled_sock is not None:
            try:
                # Quick liveness check — peek without consuming
                _pooled_sock.settimeout(0.1)
                _pooled_sock.recv(1, socket.MSG_PEEK)
                _pooled_sock.settimeout(30)
                return _pooled_sock, _pooled_reader
            except (socket.timeout, ConnectionError, OSError):
                # Stale — close and recreate
                try:
                    _pooled_sock.close()
                except OSError:
                    pass

        # Create new connection
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TCP_TIMEOUT)
        sock.connect((host, port))
        _pooled_sock = sock
        _pooled_reader = sock.makefile("r", encoding="utf-8")
        return _pooled_sock, _pooled_reader


def _close_pooled_connection():
    """Close and clear the pooled connection."""
    global _pooled_sock, _pooled_reader
    if _pooled_lock:
        with _pooled_lock:
            if _pooled_sock:
                try:
                    _pooled_sock.close()
                except OSError:
                    pass
                _pooled_sock = None
                _pooled_reader = None


def _auto_detect_bridge_dir():
    """Walk up from script location to find tools/claude-bridge/watcher."""
    env = os.environ.get("BRIDGE_DIR")
    if env:
        return env
    for start in (os.path.dirname(os.path.abspath(__file__)), os.getcwd()):
        cur = start
        for _ in range(10):
            candidate = os.path.join(cur, "watcher")
            if os.path.isdir(candidate):
                return candidate
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    import glob
    matches = glob.glob("/sessions/*/mnt/zebbingo/tools/claude-bridge/watcher")
    if matches:
        return matches[0]
    return ""


BRIDGE_DIR = _auto_detect_bridge_dir()


# ── TCP Bridge ─────────────────────────────────────────────────────────

def tcp_send_command(cmd, host=BRIDGE_HOST, port=BRIDGE_PORT, timeout=None):
    """Send command via TCP to bridge_agent, return result dict."""
    if "cmd_id" not in cmd:
        cmd["cmd_id"] = f"c_{uuid.uuid4().hex[:12]}"

    actual_timeout = timeout or cmd.get("timeout", 30)
    # TCP-level timeout = connect timeout; we'll wait longer for the response
    # V3.5: Try pooled connection first, fall back to fresh connect
    pooled_sock = None
    pooled_reader = None
    try:
        pooled_sock, pooled_reader = _get_pooled_connection(host, port)
    except Exception:
        _close_pooled_connection()
        pooled_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        pooled_sock.settimeout(TCP_TIMEOUT)
        pooled_sock.connect((host, port))
        pooled_reader = pooled_sock.makefile("r", encoding="utf-8")

    try:
        # Send command + newline
        payload = json.dumps(cmd, ensure_ascii=False) + "\n"
        pooled_sock.sendall(payload.encode("utf-8"))

        # Read response (newline-delimited)
        pooled_sock.settimeout(actual_timeout + 15)
        line = pooled_reader.readline()
        if not line:
            _close_pooled_connection()
            raise ConnectionError("Connection closed before response")
        return json.loads(line.strip())

    except (socket.timeout, ConnectionError, ConnectionRefusedError) as e:
        _close_pooled_connection()
        err_type = ("tcp_timeout" if isinstance(e, socket.timeout)
                    else "tcp_refused" if isinstance(e, ConnectionRefusedError)
                    else "tcp_error")
        err_msg = ("[TCP TIMEOUT]" if err_type == "tcp_timeout"
                   else "[TCP CONNECTION REFUSED]" if err_type == "tcp_refused"
                   else str(e))
        return {
            "state": "error", "cmd_id": cmd.get("cmd_id", ""),
            "exit_code": -1, "stdout": "", "stderr": err_msg,
            "error": err_type, "duration_ms": 0,
        }
    except Exception as e:
        _close_pooled_connection()
        return {
            "state": "error", "cmd_id": cmd.get("cmd_id", ""),
            "exit_code": -1, "stdout": "", "stderr": str(e),
            "error": "tcp_error", "duration_ms": 0,
        }


def tcp_ping(host=BRIDGE_HOST, port=BRIDGE_PORT):
    """Quick health check to bridge_agent."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(3)
    try:
        sock.connect((host, port))
        sock.sendall(b'{"type":"ping"}\n')
        buf = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
            if b"\n" in buf:
                line, _ = buf.split(b"\n", 1)
                return json.loads(line.decode("utf-8"))
    except Exception as e:
        return {"type": "pong", "error": str(e), "watcher_alive": False}
    finally:
        sock.close()
    return {"type": "pong", "error": "no response", "watcher_alive": False}


# ── File Bridge (Fallback) ─────────────────────────────────────────────

def file_send_command(cmd, bridge_dir=BRIDGE_DIR):
    """Fallback: write to queue.txt, poll for result file."""
    if "cmd_id" not in cmd:
        cmd["cmd_id"] = f"f_{uuid.uuid4().hex[:12]}"

    cmd_id = cmd["cmd_id"]
    queue_path = os.path.join(bridge_dir, "queue.txt")
    result_path = os.path.join(bridge_dir, f"r_{cmd_id}.json")
    timeout = cmd.get("timeout", 30)

    pending = {
        "state": "pending",
        "cmd_id": cmd_id,
        "command": cmd["command"],
        "type": cmd.get("type", "powershell"),
        "timeout": timeout,
    }

    # Write to queue with fsync (force 9P flush to reach Windows)
    try:
        with open(queue_path, "w", encoding="utf-8") as f:
            f.write(json.dumps(pending, ensure_ascii=False))
            f.flush()
            os.fsync(f.fileno())  # Force 9P write-back cache flush
    except Exception as e:
        return {
            "state": "error", "cmd_id": cmd_id,
            "exit_code": -1, "stdout": "", "stderr": f"queue write failed: {e}",
            "error": "file_write_failed", "duration_ms": 0,
        }

    # Poll for result
    deadline = time.monotonic() + timeout + 15
    while time.monotonic() < deadline:
        try:
            with open(result_path, "r", encoding="utf-8") as f:
                result = json.load(f)
            # Cleanup
            try:
                os.unlink(result_path)
            except OSError:
                pass
            return result
        except (FileNotFoundError, json.JSONDecodeError):
            time.sleep(0.1)

    return {
        "state": "error", "cmd_id": cmd_id,
        "exit_code": -1, "stdout": "", "stderr": f"[FILE TIMEOUT after {timeout}s]",
        "error": "file_timeout", "duration_ms": int(timeout * 1000),
    }


# ── Unified API ────────────────────────────────────────────────────────

def send_command(cmd, force_fallback=False):
    """Send command via TCP with file fallback."""
    if force_fallback:
        return file_send_command(cmd), "file"

    t0 = time.monotonic()
    result = tcp_send_command(cmd)
    elapsed = (time.monotonic() - t0) * 1000

    # V3.5: One fast TCP retry before expensive file fallback.
    # bridge_agent may have restarted (watchdog cycle ~30s) or a transient
    # network blip. A 200ms wait + reconnect is much cheaper than a full
    # file fallback (~200ms total with polling).
    if result.get("error") in ("tcp_refused", "tcp_timeout", "tcp_error"):
        time.sleep(TCP_FAST_RETRY_MS / 1000.0)
        _close_pooled_connection()
        retry_result = tcp_send_command(cmd)
        if retry_result.get("error") not in ("tcp_refused", "tcp_timeout", "tcp_error"):
            return retry_result, "tcp_retry"

        # Both TCP attempts failed — fall back to file
        result["tcp_fallback"] = True
        result["tcp_error"] = result.get("stderr", "")
        result["tcp_ms"] = int(elapsed)
        return file_send_command(cmd), "file_fallback"

    return result, "tcp"


# ── CLI ────────────────────────────────────────────────────────────────

def main():
    args = sys.argv[1:]

    if not args:
        print(__doc__)
        sys.exit(1)

    # --ping
    if "--ping" in args:
        result = tcp_ping()
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    # --fallback force
    force_fallback = "--fallback" in args

    # Parse command — strip --flags first so position doesn't matter
    positional = [a for a in args if not a.startswith("--")]
    if positional and positional[0].startswith("{"):
        # Raw JSON (works even if --fallback comes before JSON)
        cmd = json.loads(positional[0])
    elif "--cmd" in args:
        # --cmd "echo hello" --type powershell --timeout 30
        cmd = {"command": args[args.index("--cmd") + 1]}
        if "--type" in args:
            cmd["type"] = args[args.index("--type") + 1]
        if "--timeout" in args:
            cmd["timeout"] = int(args[args.index("--timeout") + 1])
    elif positional:
        # Treat first positional arg as the command string
        cmd = {"command": positional[0], "type": "powershell", "timeout": 30}
    else:
        print("No command argument provided")
        sys.exit(1)

    result, channel = send_command(cmd, force_fallback=force_fallback)
    result["_channel"] = channel
    print(json.dumps(result, indent=2, ensure_ascii=False))

    # Exit code
    sys.exit(result.get("exit_code", 1))


if __name__ == "__main__":
    main()
