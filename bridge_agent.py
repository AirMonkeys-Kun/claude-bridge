#!/usr/bin/env python3
"""
bridge_agent.py — TCP gateway for Claude Bridge (Phase 4 Step 2: hardened)

Architecture (process pair):
  bridge_agent.py               → TCP server + /health HTTP endpoint
  bridge_agent_watchdog.py      → independent subprocess (monitors watcher + parent)

Each monitors the other: bridge_agent restarts watchdog if it dies; watchdog
restarts bridge_agent if it dies. The watcher is monitored by the watchdog.

Improvements over Phase 1+3:
  - Watchdog is a true subprocess, not a daemon thread
  - SIGINT/SIGTERM graceful shutdown
  - ThreadPoolExecutor for client handling
  - /health HTTP endpoint on port 19851
  - Exponential backoff in pipe dispatch retry

Usage:
    python bridge_agent.py [--port 19850]

Protocol (TCP JSON-line):
    Request:  {"cmd_id":"xxx","command":"echo hi","type":"powershell","timeout":30}\n
    Response: {"state":"done","cmd_id":"xxx","exit_code":0,"stdout":"hi\r\n",...}\n
    Ping:     {"type":"ping"}\n
    Pong:     {"type":"pong","workers":14,"inflight":0}\n

Health endpoint (HTTP):
    GET http://localhost:19851/health  →  {"status":"ok","watcher_alive":true,...}
"""

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from bridge_agent.config import (
    DEFAULT_PORT, MAX_CONCURRENT, THREAD_POOL_SIZE,
    QUEUE_FILE, WATCHER_DIR, HEALTH_PORT,
    WATCHDOG_CHECK_INTERVAL, WATCHDOG_STALE_SECONDS,
    active_connections, active_lock,
)
from bridge_agent.pool import load_worker_pool, is_pid_alive
from bridge_agent.dispatch import execute_command, reset_queue, log


# ── Global state ──────────────────────────────────────────────────────

_shutdown_event = threading.Event()
_watchdog_proc = None
_watchdog_proc_lock = threading.Lock()
_start_time = time.time()


def _emergency_log(msg):
    """Last-resort logging — avoids log() in case dispatch.log() is broken."""
    ts = time.localtime()
    line = f"[{ts.tm_year:04d}-{ts.tm_mon:02d}-{ts.tm_mday:02d} "
    line += f"{ts.tm_hour:02d}:{ts.tm_min:02d}:{ts.tm_sec:02d}] {msg}\n"
    try:
        with open(Path(__file__).resolve().parent / "bridge_agent_stdout.log", "a", encoding="utf-8") as f:
            f.write("[EMERGENCY] " + line)
    except OSError:
        pass
    sys.stderr.write("[EMERGENCY] " + line)
    sys.stderr.flush()


# ── Signal handling ───────────────────────────────────────────────────

def _signal_handler(signum, frame):
    """Handle SIGINT/SIGTERM: set shutdown flag for graceful teardown."""
    signame = "SIGTERM" if signum == signal.SIGTERM else "SIGINT"
    log(f"[SIGNAL] Received {signame} — initiating graceful shutdown")
    _shutdown_event.set()


def _setup_signal_handlers():
    """Register signal handlers. Windows supports SIGINT, SIGTERM, SIGBREAK."""
    try:
        signal.signal(signal.SIGINT, _signal_handler)
    except (ValueError, OSError):
        pass
    try:
        signal.signal(signal.SIGTERM, _signal_handler)
    except (ValueError, OSError):
        pass
    # SIGBREAK is Windows-specific (Ctrl+Break)
    try:
        signal.signal(signal.SIGBREAK, _signal_handler)
    except (AttributeError, ValueError, OSError):
        pass


# ── Ping handler ──────────────────────────────────────────────────────

def handle_ping():
    """Return system status for health checks."""
    pool = load_worker_pool()
    workers = pool.get("workers", []) if pool else []
    alive = sum(1 for w in workers if is_pid_alive(w["pid"]))

    watcher_alive = False
    hb_file = WATCHER_DIR / ".watcher_heartbeat"
    try:
        mtime = os.path.getmtime(hb_file)
        watcher_alive = (time.time() - mtime) < WATCHDOG_STALE_SECONDS
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


# ── Connection handler ────────────────────────────────────────────────

def handle_client(conn, addr):
    """Handle a single TCP client connection (multiple commands)."""
    global active_connections
    with active_lock:
        active_connections += 1
    log(f"Connection from {addr} (active: {active_connections})")

    try:
        conn.settimeout(1.0)  # allow periodic shutdown check
        buf = b""
        while not _shutdown_event.is_set():
            try:
                chunk = conn.recv(4096)
                if not chunk:
                    break
            except socket.timeout:
                continue
            except OSError:
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

                try:
                    conn.sendall(json.dumps(result, ensure_ascii=False).encode("utf-8") + b"\n")
                except OSError:
                    log(f"  [{result.get('cmd_id','')}] Failed to send result — connection closed")
                    break

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
        try:
            conn.close()
        except OSError:
            pass
        log(f"Disconnected {addr} (active: {active_connections})")


# ── Health HTTP server ────────────────────────────────────────────────

class HealthHandler:
    """Minimal HTTP /health endpoint without external dependencies."""

    RESP_OK = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
    RESP_503 = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"

    def build(self):
        """Build health response dict."""
        uptime_secs = int(time.time() - _start_time)
        pool = load_worker_pool()
        workers = pool.get("workers", []) if pool else []
        alive_workers = sum(1 for w in workers if is_pid_alive(w["pid"]))

        watcher_alive = False
        hb_file = WATCHER_DIR / ".watcher_heartbeat"
        try:
            mtime = os.path.getmtime(hb_file)
            watcher_alive = (time.time() - mtime) < WATCHDOG_STALE_SECONDS
        except OSError:
            pass

        with _watchdog_proc_lock:
            watchdog_alive = (
                _watchdog_proc is not None
                and _watchdog_proc.poll() is None
            )

        return {
            "status": "ok",
            "uptime_secs": uptime_secs,
            "watcher_alive": watcher_alive,
            "watchdog_alive": watchdog_alive,
            "workers_total": len(workers),
            "workers_alive": alive_workers,
            "active_connections": active_connections,
            "shutting_down": _shutdown_event.is_set(),
        }

    def serve(self):
        """Run a simple HTTP server on HEALTH_PORT serving /health."""
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            srv.bind(("0.0.0.0", HEALTH_PORT))
            srv.listen(5)
            srv.settimeout(1.0)
            log(f"  Health HTTP:    0.0.0.0:{HEALTH_PORT}/health")
        except OSError as e:
            log(f"  Health HTTP:    FAILED to bind port {HEALTH_PORT}: {e}")
            return

        while not _shutdown_event.is_set():
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            try:
                conn.settimeout(2.0)
                data = conn.recv(1024)
                if data:
                    path = data.decode("utf-8", errors="replace").split(" ")[1] if len(data.split(b" ")) > 1 else "/"
                    if path == "/health":
                        body = json.dumps(self.build(), ensure_ascii=False)
                        conn.sendall((self.RESP_OK + body).encode("utf-8"))
                    else:
                        body = '{"error":"not_found"}'
                        conn.sendall((self.RESP_503 + body).encode("utf-8"))
            except OSError:
                pass
            finally:
                try:
                    conn.close()
                except OSError:
                    pass

        srv.close()
        log("Health HTTP server stopped")


# ── Watchdog subprocess management ────────────────────────────────────

def _launch_watchdog():
    """Launch watchdog as a subprocess. Returns Popen or None."""
    global _watchdog_proc
    watchdog_script = Path(__file__).resolve().parent / "bridge_agent_watchdog.py"
    if not watchdog_script.exists():
        log(f"[WATCHDOG] Script not found: {watchdog_script}")
        return None

    parent_pid = os.getpid()
    try:
        # Route stderr to a file so crash traces are diagnosable
        stderr_log = watchdog_script.parent / "bridge_agent_watchdog_stderr.log"
        stderr_fh = open(stderr_log, "a", encoding="utf-8")
        proc = subprocess.Popen(
            [sys.executable, str(watchdog_script), "--parent-pid", str(parent_pid)],
            cwd=str(watchdog_script.parent),
            creationflags=subprocess.CREATE_NO_WINDOW,
            stdout=subprocess.DEVNULL,
            stderr=stderr_fh,
        )
        with _watchdog_proc_lock:
            _watchdog_proc = proc
        log(f"[WATCHDOG] Launched watchdog subprocess PID={proc.pid} (parent PID={parent_pid})")
        return proc
    except Exception as e:
        log(f"[WATCHDOG] Failed to launch watchdog: {e}")
        return None


def _watchdog_watchman():
    """Background thread that monitors the watchdog subprocess health.

    If the watchdog dies, restart it with exponential backoff.
    CRITICAL: catch-all exception handler prevents silent thread death.
    """
    backoff = 1
    max_backoff = 30

    while not _shutdown_event.is_set():
        try:
            time.sleep(WATCHDOG_CHECK_INTERVAL)

            with _watchdog_proc_lock:
                proc = _watchdog_proc
                alive = proc is not None and proc.poll() is None

            if alive:
                backoff = 1  # reset on success
                continue

            if _shutdown_event.is_set():
                break

            log(f"[WATCHDOG] Watchdog subprocess is dead — restarting (backoff={backoff}s)")
            time.sleep(backoff)
            _launch_watchdog()
            backoff = min(backoff * 2, max_backoff)
        except Exception as e:
            import traceback
            tb = traceback.format_exc()
            # Emergency direct stderr write — log() itself may be broken
            _emergency_log(f"[WATCHDOG] Unhandled in watchman: {e}\n{tb}")
            time.sleep(5)


# ── Graceful shutdown ─────────────────────────────────────────────────

def _wait_for_inflight(done_event, timeout=30):
    """Wait for active connections to drain, then signal done."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with active_lock:
            if active_connections == 0:
                break
        time.sleep(0.5)

    log(f"Shutdown complete — {active_connections} active connections remaining")
    done_event.set()


# ── Main ──────────────────────────────────────────────────────────────

def main():
    port = int(os.environ.get("BRIDGE_PORT", DEFAULT_PORT))
    global _start_time, _watchdog_proc
    _start_time = time.time()

    _setup_signal_handlers()

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

    log(f"bridge_agent.py Phase 4 (hardened) starting")
    log(f"  Listening:     0.0.0.0:{port}")
    log(f"  Worker pool:   {alive_count} alive workers")
    log(f"  Pipe mode:     {pipe_mode}")
    log(f"  Queue fallback: {QUEUE_FILE}")
    log(f"  Max clients:   {MAX_CONCURRENT}")
    log(f"  Thread pool:   {THREAD_POOL_SIZE} workers")
    log(f"  Health HTTP:   0.0.0.0:{HEALTH_PORT}/health")
    log(f"  Watchdog:      bridge_agent_watchdog.py (subprocess)")

    reset_queue()

    # ── Launch watchdog subprocess ───────────────────────────────────
    _launch_watchdog()

    # ── Start watchdog health monitor (watcher for the watchdog) ─────
    watchman = threading.Thread(target=_watchdog_watchman, daemon=True, name="watchdog-watchman")
    watchman.start()
    log(f"  Watchdog watchman:  active (check every {WATCHDOG_CHECK_INTERVAL}s)")

    # ── Start health HTTP server (background thread) ──────────────────
    health = HealthHandler()
    health_thread = threading.Thread(target=health.serve, daemon=True, name="health-http")
    health_thread.start()

    # ── Main TCP server ──────────────────────────────────────────────
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(MAX_CONCURRENT)
    srv.settimeout(1.0)  # allow periodic shutdown check

    log(f"Ready — Phase 4 (pipe direct + queue fallback)")

    try:
        with ThreadPoolExecutor(max_workers=THREAD_POOL_SIZE) as pool:
            while not _shutdown_event.is_set():
                try:
                    conn, addr = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break

                pool.submit(handle_client, conn, addr)
    except KeyboardInterrupt:
        pass
    finally:
        log("Shutting down gracefully...")
        srv.close()

        # Wait for in-flight connections to drain
        done = threading.Event()
        waiter = threading.Thread(target=_wait_for_inflight, args=(done,), daemon=True)
        waiter.start()
        done.wait(timeout=30)

        # Terminate watchdog subprocess
        with _watchdog_proc_lock:
            if _watchdog_proc and _watchdog_proc.poll() is None:
                log(f"Terminating watchdog subprocess PID={_watchdog_proc.pid}")
                try:
                    _watchdog_proc.terminate()
                    _watchdog_proc.wait(timeout=5)
                except Exception:
                    try:
                        _watchdog_proc.kill()
                        _watchdog_proc.wait(timeout=2)
                    except Exception:
                        pass

        log("bridge_agent.py shutdown complete")


if __name__ == "__main__":
    if "--help" in sys.argv:
        print(__doc__)
        sys.exit(0)
    main()
