#!/usr/bin/env python3
"""
bridge_agent_watchdog.py — Independent watchdog subprocess (Phase 4 Step 2)

Spawned by bridge_agent.py as a subprocess. Monitors:
  1. Watcher heartbeat — if stale, launch restarter to recover the watcher
  2. Parent bridge_agent process — if dead, restart bridge_agent

This is a true subprocess (not a daemon thread), so it survives if the parent
process's Python runtime is compromised. The pair forms a "process pair"
architecture: each monitors the other.

Usage (spawned by bridge_agent, not intended for direct invocation):
    python bridge_agent_watchdog.py --parent-pid <PID>

Protocol:
    Watchdog logs to bridge_agent_watchdog.log in the script directory.
    Watchdog writes .watchdog_heartbeat for parent to verify it's alive.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
WATCHER_DIR = SCRIPT_DIR / "watcher"
LOG_FILE = SCRIPT_DIR / "bridge_agent_watchdog.log"
HEARTBEAT_FILE = SCRIPT_DIR / "watcher" / ".watchdog_heartbeat"
LOCK_FILE = WATCHER_DIR / ".watcher.lock"
HB_FILE = WATCHER_DIR / ".watcher_heartbeat"
RESTARTER = WATCHER_DIR / "restarter.ps1"
WATCHER_PS1 = WATCHER_DIR / "watcher.ps1"
BRIDGE_AGENT = SCRIPT_DIR / "bridge_agent.py"

STALE_SECONDS = 120        # watcher heartbeat stale threshold
CHECK_INTERVAL = 60         # seconds between watcher heartbeat checks
PARENT_CHECK_INTERVAL = 30  # seconds between parent-PID checks
HEARTBEAT_INTERVAL = 15     # seconds between .watchdog_heartbeat updates
RESTART_BACKOFF_BASE = 2    # exponential backoff for restart retries
RESTART_MAX_BACKOFF = 30    # max backoff between restart attempts
WATCHDOG_LOG_MAX_BYTES = 1 * 1024 * 1024  # 1MB log rotation


def log(msg):
    """Write a timestamped line to the watchdog log file."""
    ts = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())
    line = f"[{ts}] {msg}\n"
    try:
        _rotate_if_needed()
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass  # best-effort logging
    print(line, end="", flush=True)


def _rotate_if_needed():
    """Rotate log file if it exceeds max bytes."""
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > WATCHDOG_LOG_MAX_BYTES:
            bak = LOG_FILE.with_suffix(".log.1")
            if bak.exists():
                bak.unlink()
            LOG_FILE.rename(bak)
    except OSError:
        pass


def write_heartbeat():
    """Update .watchdog_heartbeat with current timestamp."""
    try:
        WATCHER_DIR.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%d %H:%M:%S.%f")[:23]
        # Temp+rename for atomic write
        tmp = HEARTBEAT_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(ts)
        tmp.replace(HEARTBEAT_FILE)
    except OSError:
        pass


def is_process_alive(pid):
    """Check if a PID is alive on Windows."""
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259

        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_bool, ctypes.c_ulong]
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            return False
        exit_code = ctypes.c_ulong()
        kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
        kernel32.CloseHandle(handle)
        return exit_code.value == STILL_ACTIVE
    except Exception:
        return False


def is_watcher_alive():
    """Check watcher heartbeat freshness."""
    try:
        mtime = os.path.getmtime(HB_FILE)
        return (time.time() - mtime) < STALE_SECONDS
    except OSError:
        return False


def launch_restarter():
    """Launch restarter.ps1 to recover the watcher."""
    log("[WATCHDOG] Watcher heartbeat stale — initiating restart")
    try:
        if LOCK_FILE.exists():
            LOCK_FILE.unlink()
            log("  Removed stale .watcher.lock")
    except OSError as e:
        log(f"  Could not remove lock: {e}")

    if RESTARTER.exists():
        try:
            proc = subprocess.Popen(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", str(RESTARTER),
                 "-OldPID", "0",
                 "-WatcherPath", str(WATCHER_PS1)],
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            log(f"  Launched restarter PID={proc.pid}")
        except Exception as e:
            log(f"  Failed to launch restarter: {e}")
    elif WATCHER_PS1.exists():
        try:
            subprocess.Popen(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", str(WATCHER_PS1)],
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            log("  Launched watcher.ps1 directly")
        except Exception as e:
            log(f"  Failed to launch watcher.ps1: {e}")


def launch_bridge_agent():
    """Launch a new bridge_agent.py instance."""
    log("[WATCHDOG] Launching new bridge_agent.py")
    try:
        proc = subprocess.Popen(
            [sys.executable, str(BRIDGE_AGENT)],
            cwd=str(SCRIPT_DIR),
            creationflags=subprocess.CREATE_NO_WINDOW,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log(f"  Launched bridge_agent PID={proc.pid}")
        return proc.pid
    except Exception as e:
        log(f"  Failed to launch bridge_agent: {e}")
        return None


def main():
    parser = argparse.ArgumentParser(description="bridge_agent watchdog subprocess")
    parser.add_argument("--parent-pid", type=int, required=True,
                        help="PID of the parent bridge_agent process")
    args = parser.parse_args()

    parent_pid = args.parent_pid
    log(f"=== Watchdog started (parent PID={parent_pid}) ===")
    log(f"  Script dir:  {SCRIPT_DIR}")
    log(f"  Watcher dir: {WATCHER_DIR}")
    log(f"  Log file:    {LOG_FILE}")

    # State
    restart_count = 0
    last_watcher_recovery = 0
    last_parent_check = 0
    last_heartbeat = 0
    last_bridge_recovery = 0
    watcher_was_alive = is_watcher_alive()
    parent_was_alive = is_process_alive(parent_pid)

    log(f"  Initial state: watcher_alive={watcher_was_alive} parent_alive={parent_was_alive}")

    while True:
        now = time.monotonic()
        now_ts = time.time()

        # ── 1. Update watchdog heartbeat ─────────────────────────────
        if now - last_heartbeat >= HEARTBEAT_INTERVAL:
            write_heartbeat()
            last_heartbeat = now

        # ── 2. Check parent bridge_agent ─────────────────────────────
        if now - last_parent_check >= PARENT_CHECK_INTERVAL:
            last_parent_check = now
            alive = is_process_alive(parent_pid)
            if not alive:
                log(f"[WATCHDOG] Parent PID={parent_pid} is dead")
                # Only attempt recovery if enough time has passed
                if now - last_bridge_recovery >= RESTART_MAX_BACKOFF + 5:
                    restart_count += 1
                    backoff = min(RESTART_BACKOFF_BASE ** restart_count, RESTART_MAX_BACKOFF)
                    log(f"  Recovery attempt #{restart_count} (backoff={backoff}s)")
                    new_pid = launch_bridge_agent()
                    if new_pid:
                        parent_pid = new_pid  # monitor the new instance
                        last_bridge_recovery = now
                        restart_count = 0  # reset counter on success
                    else:
                        time.sleep(backoff)
                        continue
                else:
                    # Too soon since last recovery — keep waiting
                    time.sleep(1)
                    continue
            else:
                # Parent alive — reset counter
                if restart_count > 0:
                    restart_count = 0

        # ── 3. Check watcher heartbeat ───────────────────────────────
        if now - last_watcher_recovery >= CHECK_INTERVAL:
            last_watcher_recovery = now
            if not is_watcher_alive():
                launch_restarter()

        time.sleep(1)


if __name__ == "__main__":
    main()
