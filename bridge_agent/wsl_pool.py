"""
wsl_pool.py — Persistent wsl.exe process pool for bridge_agent.

Instead of spawning a new wsl.exe for each WSL command (which costs ~30-50ms
cold start each time, see worker_generic.ps1 subprocess fallback), we keep
a single wsl.exe alive in the bridge_agent process and feed it commands
through stdin/stdout with a marker-based protocol.

Why in bridge_agent (Python) instead of a new PowerShell worker:
  - Python subprocess + threaded readline is more reliable than PowerShell
    runspace-internal Process management
  - Doesn't touch the 16-worker pool deployed by worker_factory.ps1
  - Easier to extend (pool size > 1, restart-on-crash, etc.)

Protocol (per command):
  Send:     <user_cmd>; printf '\\n<MARKER> %s\\n' "$?"\n
  Receive:  <stdout lines...>\n<MARKER> <exit_code>\n
  MARKER:   ___WSLEND_<uuid_hex>___ (unique per command, prevents collision
            with user output that happens to contain a sentinel)

Concurrency:
  Single wsl.exe = single command at a time. A threading.Lock serializes
  access. If pool_size > 1 in the future, dispatch round-robin.
"""
import os
import queue
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path


_LOG_FILE = Path(__file__).resolve().parent.parent / "wsl_pool.log"


def _log(msg):
    """Best-effort log to wsl_pool.log next to bridge_agent_stdout.log."""
    try:
        n = time.localtime()
        ts = f"{n.tm_year:04d}-{n.tm_mon:02d}-{n.tm_mday:02d} {n.tm_hour:02d}:{n.tm_min:02d}:{n.tm_sec:02d}"
        with open(_LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"[{ts}] {msg}\n")
    except OSError:
        pass


class _WslProc:
    """A single persistent wsl.exe instance, lock-protected."""

    def __init__(self, name="wsl-1"):
        self.name = name
        self._lock = threading.Lock()
        self._proc = None
        self._stdin = None
        self._stdout = None
        self._stderr_lines = []     # V3.5: captured stderr buffer
        self._stderr_lock = threading.Lock()
        self._cmd_count = 0
        self._last_used = 0.0
        self._restarting = False
        self._start()

    def _start(self):
        """Launch wsl.exe with stdin/stdout pipes."""
        try:
            self._proc = subprocess.Popen(
                ["wsl.exe", "-e", "bash", "--norc"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                bufsize=1,
                encoding="utf-8",
                errors="replace",
                cwd="C:\\",
            )
            self._stdin = self._proc.stdin
            self._stdout = self._proc.stdout
            # Drain stderr in background so it can't deadlock the pipe
            t = threading.Thread(target=self._drain_stderr, daemon=True, name=f"{self.name}-stderr-drain")
            t.start()
            self._last_used = time.time()
            _log(f"[{self.name}] wsl.exe started PID={self._proc.pid}")
        except Exception as e:
            _log(f"[{self.name}] FAILED to start wsl.exe: {e}")
            self._proc = None

    def _drain_stderr(self):
        """Background thread: consume stderr continuously, capture to buffer."""
        if not self._proc or not self._proc.stderr:
            return
        try:
            while True:
                line = self._proc.stderr.readline()
                if not line:
                    break
                # V3.5: capture stderr for per-command return instead of discarding
                with self._stderr_lock:
                    self._stderr_lines.append(line)
                    if len(self._stderr_lines) > 200:
                        self._stderr_lines = self._stderr_lines[-100:]
        except OSError:
            pass

    def _snapshot_stderr(self):
        """V3.5: return captured stderr lines since last exec() call."""
        with self._stderr_lock:
            lines = list(self._stderr_lines)
            self._stderr_lines.clear()
        return "".join(lines)

    def _readline_with_timeout(self, timeout_s):
        """
        V3.4.3: True deadline-based readline.

        Runs blocking readline() in a daemon thread, returns via queue with
        timeout. On timeout we abandon the reader thread (daemon, harmless) and
        the caller restarts wsl.exe to clear the stuck state.

        Returns tuple:
          ('line', line_str)   — got a line
          ('eof', None)        — wsl.exe exited (empty line)
          ('error', exception) — OSError during read
          ('timeout', None)    — deadline fired before readline returned
        """
        if not self._stdout:
            return ('eof', None)

        result_q = queue.Queue()

        def _reader():
            try:
                line = self._stdout.readline()
                if line:
                    result_q.put(('line', line))
                else:
                    result_q.put(('eof', None))
            except OSError as e:
                result_q.put(('error', e))

        t = threading.Thread(target=_reader, daemon=True, name=f"{self.name}-rd")
        t.start()
        try:
            return result_q.get(timeout=timeout_s)
        except queue.Empty:
            return ('timeout', None)

    def is_alive(self):
        return self._proc is not None and self._proc.poll() is None

    def _restart_if_dead(self):
        if not self.is_alive():
            _log(f"[{self.name}] wsl.exe died (exit={self._proc.returncode if self._proc else 'n/a'}) — restarting")
            try:
                if self._stdin:
                    self._stdin.close()
            except OSError:
                pass
            self._start()

    def exec(self, command, timeout=30):
        """Execute a command. Returns dict with exit_code, stdout, stderr, duration_ms."""
        with self._lock:
            self._restart_if_dead()
            if not self.is_alive():
                return {
                    "exit_code": -1, "stdout": "", "stderr": self._snapshot_stderr(),
                    "error": "wsl_process_unavailable",
                    "duration_ms": 0,
                }

            marker = f"___WSLEND_{uuid.uuid4().hex[:16]}___"
            # Send command + marker line. Use printf to ensure exact format.
            # Exit code is captured by $? immediately after user command.
            payload = f"{command}; printf '\\n{marker} %s\\n' \"$?\"\n"

            t0 = time.monotonic()
            try:
                self._stdin.write(payload)
                self._stdin.flush()
            except (BrokenPipeError, OSError) as e:
                _log(f"[{self.name}] stdin write failed: {e} — restarting")
                self._start()
                return {
                    "exit_code": -1, "stdout": "", "stderr": self._snapshot_stderr(),
                    "error": f"stdin_write_failed: {e}",
                    "duration_ms": int((time.monotonic() - t0) * 1000),
                }

            # Read stdout until marker line. V3.4.3: TRUE deadline-based timeout
            # via threaded readline + queue.get(timeout=...). Previous code used
            # blocking readline() which ignored the deadline — a hanging command
            # (e.g. `read var`, deadlock, network stall) occupied the pool far
            # beyond the requested timeout.
            marker_re = re.compile(rf"^{re.escape(marker)}\s+(-?\d+)\s*$")
            output_lines = []
            exit_code = None
            deadline = time.monotonic() + timeout

            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break  # true timeout fired

                # Threaded readline: returns ('line', text) | ('eof', None) | ('timeout', None)
                line_result = self._readline_with_timeout(remaining)
                kind = line_result[0]

                if kind == "timeout":
                    break  # deadline fired
                if kind == "eof":
                    _log(f"[{self.name}] stdout EOF — wsl.exe exited mid-command")
                    break
                if kind == "error":
                    _log(f"[{self.name}] stdout read failed: {line_result[1]}")
                    break
                if kind != "line":
                    break
                line = line_result[1]

                m = marker_re.match(line.rstrip("\r\n"))
                if m:
                    exit_code = int(m.group(1))
                    break
                output_lines.append(line)

            elapsed_ms = int((time.monotonic() - t0) * 1000)
            self._cmd_count += 1
            self._last_used = time.time()

            if exit_code is None:
                # Timed out or EOF before marker
                _log(f"[{self.name}] cmd timed out or wsl EOF after {elapsed_ms}ms — restarting")
                self._start()
                return {
                    "exit_code": -1,
                    "stdout": "".join(output_lines),
                    "stderr": self._snapshot_stderr(),
                    "error": "timeout_or_eof",
                    "duration_ms": elapsed_ms,
                }

            return {
                "exit_code": exit_code,
                "stdout": "".join(output_lines),
                "stderr": self._snapshot_stderr(),
                "error": "",
                "duration_ms": elapsed_ms,
            }


class WslPool:
    """Pool of persistent wsl.exe processes. Default size 1 (serial).

    Why pool of 1: bridge_agent already serializes via queue_serial for queue
    fallback; pipe dispatch goes through worker pool. For WSL, single persistent
    process is simpler and avoids WSL2's per-instance ~50MB memory cost.
    """

    def __init__(self, pool_size=2):
        self._size = pool_size
        self._procs = []
        self._rr_idx = 0
        self._pool_lock = threading.Lock()
        for i in range(pool_size):
            self._procs.append(_WslProc(name=f"wsl-{i+1}"))

    def exec(self, command, timeout=30):
        """Round-robin dispatch to next wsl proc."""
        with self._pool_lock:
            proc = self._procs[self._rr_idx % self._size]
            self._rr_idx += 1
        return proc.exec(command, timeout)

    def health(self):
        """Return pool health dict for /health endpoint."""
        alive = sum(1 for p in self._procs if p.is_alive())
        total_cmds = sum(p._cmd_count for p in self._procs)
        return {
            "pool_size": self._size,
            "alive": alive,
            "total_cmds_executed": total_cmds,
        }


# ── Module-level singleton (lazy-initialized on first use) ─────────────
_pool_singleton = None
_pool_init_lock = threading.Lock()


def get_pool():
    """Get or create the global WslPool singleton."""
    global _pool_singleton
    if _pool_singleton is None:
        with _pool_init_lock:
            if _pool_singleton is None:
                _pool_singleton = WslPool()
                _log(f"WslPool initialized (size={_pool_singleton._size})")
    return _pool_singleton
