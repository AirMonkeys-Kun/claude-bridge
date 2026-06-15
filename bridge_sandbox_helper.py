#!/usr/bin/env python3
"""
bridge_sandbox_helper.py — Zero-polling fast bridge client for Cowork sandbox.

Design principle: NO sleep(), NO polling loops in user code.
Results come back as fast as the bridge can deliver them.

Quickest path auto-detection:
  1. TCP direct (172.16.10.254:19850) — if tap0 network exists
  2. TCP proxy (queue.txt → watcher → localhost → wsl_pool) — always available
  3. File fallback (queue.txt → watcher → worker) — final safety net

Usage:
  from bridge_sandbox_helper import Bridge
  b = Bridge()

  # Single command — zero-poll, instant result
  r = b.exec("echo hello && whoami", type="wsl")
  print(r.stdout)  # "hello\nroot"

  # Batch: send ALL at once, wait for ALL. Total = max(latency), not sum.
  results = b.batch([
      ("echo A && echo B", "wsl", 10),
      ("Get-Process -Id $PID", "powershell", 15),
      ("dir C:\\", "cmd", 10),
  ])
  for r in results:
      print(f"[{r.type}] {r.stdout[:40]}...")

  # Fan-out: same command, different params, all parallel
  urls = ["/api/health", "/api/status", "/api/metrics"]
  results = b.fanout(
      template="curl -s localhost:8765{PARAM}",
      params=[{"PARAM": u} for u in urls],
      type="wsl"
  )

  # Pipeline: each step gets previous result as context
  result = b.pipeline([
      ("find /tmp -name '*.log' | head -5", "wsl", 10),
      ("wc -l {PREV_STDOUT}", "wsl", 10),  # {PREV_STDOUT} = previous result
  ])
"""

import json
import os
import socket
import time
import uuid
import threading
import queue
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


# ── Configuration ──────────────────────────────────────────────────────
BRIDGE_HOST = os.environ.get("BRIDGE_HOST", "172.16.10.254")
BRIDGE_PORT = int(os.environ.get("BRIDGE_PORT", "19850"))


def _auto_detect_bridge_dir():
    """Find the watcher directory for queue.txt fallback."""
    env = os.environ.get("BRIDGE_DIR")
    if env:
        return env
    for start in [os.path.dirname(os.path.abspath(__file__)), os.getcwd()]:
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
    matches = glob.glob("/sessions/*/mnt/claude-bridge/watcher")
    if matches:
        return matches[0]
    return None


class BridgeResult:
    """Unified result from any bridge path."""
    def __init__(self, cmd_id, exit_code, stdout, stderr, duration_ms, channel, error=""):
        self.cmd_id = cmd_id
        self.exit_code = exit_code
        self.stdout = stdout
        self.stderr = stderr
        self.duration_ms = duration_ms
        self.channel = channel
        self.error = error
        self.ok = (exit_code == 0)

    def __repr__(self):
        return f"BridgeResult({self.cmd_id}, ch={self.channel}, exit={self.exit_code}, {self.duration_ms}ms)"


class Bridge:
    """Zero-polling bridge client. Auto-detects fastest available path."""

    def __init__(self):
        self._bridge_dir = _auto_detect_bridge_dir()
        self._tcp_available = None  # lazily tested
        self._tcp_lock = threading.Lock()
        self._tcp_sock = None
        self._tcp_reader = None

    # ── Path detection ──────────────────────────────────────────────

    def _has_tcp(self, timeout=1.0):
        """Check if TCP direct to bridge_agent is available."""
        if self._tcp_available is not None:
            return self._tcp_available
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect((BRIDGE_HOST, BRIDGE_PORT))
            s.close()
            self._tcp_available = True
            return True
        except (socket.timeout, ConnectionRefusedError, OSError):
            self._tcp_available = False
            return False

    def path_info(self):
        """Return which path is currently active."""
        if self._has_tcp(timeout=0.5):
            return "tcp_direct", f"TCP {BRIDGE_HOST}:{BRIDGE_PORT}"
        if self._bridge_dir:
            return "tcp_proxy", f"queue.txt → watcher → localhost TCP proxy"
        return "file_only", "queue.txt → watcher → worker (slowest)"

    # ── Core: single command, zero-poll, best path ─────────────────

    def exec(self, command, type="wsl", timeout=30, cmd_id=None):
        """
        Execute a single command via the fastest available path.
        Returns BridgeResult. No sleep loops in user code.
        """
        if cmd_id is None:
            cmd_id = f"cmd_{uuid.uuid4().hex[:10]}"

        if self._has_tcp(timeout=1.0):
            return self._exec_tcp(command, type, timeout, cmd_id)
        elif self._bridge_dir:
            return self._exec_queue_proxy(command, type, timeout, cmd_id)
        else:
            raise RuntimeError("No bridge path available — cannot find bridge dir")

    def _exec_tcp(self, command, type, timeout, cmd_id):
        """TCP direct path: send → recv, zero-poll. ~5ms for wsl."""
        t0 = time.monotonic()
        try:
            with self._tcp_lock:
                if self._tcp_sock is None:
                    self._tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    self._tcp_sock.settimeout(5)
                    self._tcp_sock.connect((BRIDGE_HOST, BRIDGE_PORT))
                    self._tcp_reader = self._tcp_sock.makefile("r", encoding="utf-8")

                payload = json.dumps({
                    "cmd_id": cmd_id, "command": command,
                    "type": type, "timeout": timeout
                }, ensure_ascii=False) + "\n"
                self._tcp_sock.sendall(payload.encode("utf-8"))
                self._tcp_sock.settimeout(timeout + 15)
                line = self._tcp_reader.readline()

            if not line:
                self._close_tcp()
                return BridgeResult(cmd_id, -1, "", "TCP connection closed", 0, "tcp_error", "closed")
            data = json.loads(line.strip())
            elapsed = int((time.monotonic() - t0) * 1000)
            return BridgeResult(
                cmd_id, data.get("exit_code", -1),
                data.get("stdout", ""), data.get("stderr", ""),
                elapsed, data.get("dispatch_channel", "tcp"), data.get("error", "")
            )
        except Exception as e:
            self._close_tcp()
            elapsed = int((time.monotonic() - t0) * 1000)
            return BridgeResult(cmd_id, -1, "", str(e), elapsed, "tcp_error", str(e))

    def _exec_queue_proxy(self, command, type, timeout, cmd_id):
        """
        Queue proxy path: write queue.txt → watcher TCP proxy → result file.
        V3.5.1 watcher routes type=wsl through wsl_pool (~10ms).
        Falls back to cold subprocess if TCP proxy fails.
        """
        qpath = os.path.join(self._bridge_dir, "queue.txt")
        rpath = os.path.join(self._bridge_dir, f"r_{cmd_id}.json")

        t0 = time.monotonic()
        pending = json.dumps({
            "state": "pending", "cmd_id": cmd_id,
            "command": command, "type": type, "timeout": timeout
        }, ensure_ascii=False)

        # Write to queue (fsync to force 9P flush)
        try:
            with open(qpath, "w", encoding="utf-8") as f:
                f.write(pending)
                f.flush()
                os.fsync(f.fileno())
        except OSError as e:
            return BridgeResult(cmd_id, -1, "", str(e), 0, "queue_error", str(e))

        # V3.5.2: Adaptive polling — fast initial checks, then back off.
        # Expected wsl via TCP proxy: ~10ms → result within 2 polls.
        # Expected pipe dispatch: ~30ms → result within 5 polls.
        deadline = time.monotonic() + timeout + 15
        poll_ms = 5  # start at 5ms, ramp up

        while time.monotonic() < deadline:
            try:
                with open(rpath, "r", encoding="utf-8") as f:
                    data = json.load(f)
                try:
                    os.unlink(rpath)
                except OSError:
                    pass
                elapsed = int((time.monotonic() - t0) * 1000)
                return BridgeResult(
                    cmd_id, data.get("exit_code", -1),
                    data.get("stdout", ""), data.get("stderr", ""),
                    elapsed, "tcp_proxy", data.get("error", "")
                )
            except (FileNotFoundError, json.JSONDecodeError):
                pass

            time.sleep(poll_ms / 1000.0)
            poll_ms = min(poll_ms + 5, 100)  # 5→10→15→...→100ms max

        elapsed = int((time.monotonic() - t0) * 1000)
        return BridgeResult(cmd_id, -1, "", f"timeout after {elapsed}ms", elapsed, "timeout", "timeout")

    def _close_tcp(self):
        if self._tcp_sock:
            try:
                self._tcp_sock.close()
            except OSError:
                pass
            self._tcp_sock = None
            self._tcp_reader = None

    # ── Batch: send ALL, wait for ALL. Total time ≈ max(latency) ───

    def batch(self, commands, max_workers=8):
        """
        Execute multiple commands concurrently.

        Args:
            commands: list of (command, type, timeout) tuples,
                      or list of dicts with same keys.
            max_workers: ThreadPoolExecutor size.

        Returns:
            list of BridgeResult, same order as input.

        Example:
            results = b.batch([
                ("echo A", "wsl", 10),
                ("echo B", "wsl", 10),
                ("Get-Date", "powershell", 10),
            ])
            # All 3 run in parallel. Total time ≈ max(5, 5, 17)ms.
        """
        if not commands:
            return []

        # Normalize to (cmd, type, timeout) tuples
        normalized = []
        for i, c in enumerate(commands):
            if isinstance(c, (list, tuple)):
                cmd, ctype, cto = c[0], c[1] if len(c) > 1 else "wsl", c[2] if len(c) > 2 else 30
            elif isinstance(c, dict):
                cmd, ctype, cto = c.get("command"), c.get("type", "wsl"), c.get("timeout", 30)
            else:
                raise ValueError(f"Invalid command format at index {i}: {c}")
            normalized.append((cmd, ctype, cto))

        results = [None] * len(normalized)

        # TCP path: true parallelism via thread pool
        if self._has_tcp(timeout=1.0):
            with ThreadPoolExecutor(max_workers=max_workers) as pool:
                futures = {}
                for i, (cmd, ctype, cto) in enumerate(normalized):
                    futures[pool.submit(
                        self.exec, cmd, ctype, cto, f"batch_{i}_{uuid.uuid4().hex[:6]}"
                    )] = i
                for future in as_completed(futures):
                    idx = futures[future]
                    results[idx] = future.result()
        else:
            # Queue path: serial dispatch (single queue.txt) but
            # each command goes through fast TCP proxy ~10ms.
            # We submit them as fast as possible.
            for i, (cmd, ctype, cto) in enumerate(normalized):
                results[i] = self.exec(cmd, ctype, cto)

        return results

    # ── Fan-out: same command template, different params ───────────

    def fanout(self, template, params, type="wsl", timeout=30, max_workers=8):
        """
        Execute the same command template with different parameters.

        Args:
            template: command string with {KEY} placeholders
            params: list of dicts, each dict provides values for {KEY}
            type: command type
            timeout: per-command timeout
            max_workers: ThreadPoolExecutor size

        Returns:
            list of BridgeResult, same order as params.

        Example:
            results = b.fanout(
                "curl -s localhost:8765{PATH}",
                [{"PATH": "/health"}, {"PATH": "/status"}, {"PATH": "/metrics"}],
            )
        """
        commands = []
        for p in params:
            cmd = template
            for k, v in p.items():
                cmd = cmd.replace("{" + k + "}", str(v))
            commands.append((cmd, type, timeout))
        return self.batch(commands, max_workers=max_workers)

    # ── Pipeline: sequential steps with context ─────────────────────

    def pipeline(self, steps):
        """
        Execute steps sequentially, each step can reference previous results.

        Args:
            steps: list of (command, type, timeout) tuples.
                   Use {PREV_STDOUT} to reference the previous step's stdout.
                   Use {PREV_EXIT} for the previous step's exit code.

        Returns:
            list of BridgeResult, same order as steps.

        Example:
            results = b.pipeline([
                ("find /tmp -name '*.log' | head -3", "wsl", 10),
                ("echo Found files:{PREV_STDOUT}", "wsl", 10),
            ])
        """
        results = []
        for i, step in enumerate(steps):
            if isinstance(step, (list, tuple)):
                cmd, ctype, cto = step[0], step[1] if len(step) > 1 else "wsl", step[2] if len(step) > 2 else 30
            else:
                cmd, ctype, cto = step.get("command"), step.get("type", "wsl"), step.get("timeout", 30)

            # Substitute placeholders from previous result
            if results and "{PREV_STDOUT}" in cmd:
                prev = results[-1]
                cmd = cmd.replace("{PREV_STDOUT}", prev.stdout.strip())
            if results and "{PREV_EXIT}" in cmd:
                cmd = cmd.replace("{PREV_EXIT}", str(results[-1].exit_code))

            r = self.exec(cmd, ctype, cto)
            results.append(r)
            if not r.ok and r.error:
                break  # stop pipeline on error

        return results

    # ── Health ──────────────────────────────────────────────────────

    def health(self):
        """Return bridge health summary."""
        path_name, path_desc = self.path_info()
        try:
            r = self.exec("echo HEALTH_OK", "wsl", 5)
            return {
                "path": path_name, "path_detail": path_desc,
                "latency_ms": r.duration_ms, "channel": r.channel,
                "ok": r.ok, "error": r.error,
            }
        except Exception as e:
            return {"path": path_name, "path_detail": path_desc, "error": str(e)}


# ── Module-level convenience ──────────────────────────────────────────

_default_bridge = None

def exec(command, type="wsl", timeout=30):
    """Module-level convenience: single command, fastest path."""
    global _default_bridge
    if _default_bridge is None:
        _default_bridge = Bridge()
    return _default_bridge.exec(command, type, timeout)

def batch(commands, max_workers=8):
    """Module-level convenience: concurrent batch."""
    global _default_bridge
    if _default_bridge is None:
        _default_bridge = Bridge()
    return _default_bridge.batch(commands, max_workers)

def health():
    """Module-level convenience: health check."""
    global _default_bridge
    if _default_bridge is None:
        _default_bridge = Bridge()
    return _default_bridge.health()
