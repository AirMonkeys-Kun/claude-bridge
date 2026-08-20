#!/usr/bin/env python3
"""
bridge_agent_watchdog.py -- Independent watchdog subprocess (Phase 4 Step 2)

Spawned by bridge_agent.py as a subprocess. Monitors:
  1. Watcher heartbeat -- if stale, launch restarter to recover the watcher
  2. Parent bridge_agent process -- if dead, restart bridge_agent

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
import datetime
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
MAINTENANCE_LOCK = WATCHER_DIR / ".maintenance.lock"

STALE_SECONDS = 120
CHECK_INTERVAL = 60
PARENT_CHECK_INTERVAL = 30
HEARTBEAT_INTERVAL = 15
RESTART_BACKOFF_BASE = 2
RESTART_MAX_BACKOFF = 30
WATCHDOG_LOG_MAX_BYTES = 1 * 1024 * 1024

# ── Restarter concurrency guard (prevents process accumulation) ──
_restarter_pid = None  # PID of the last launched restarter; None if none active


def _now_str():
    """strftime-free timestamp — works around broken strftime on some Python builds."""
    import datetime as _dt
    n = _dt.datetime.now()
    return f"{n.year:04d}-{n.month:02d}-{n.day:02d} {n.hour:02d}:{n.minute:02d}:{n.second:02d}"

def log(msg):
    line = f"[{_now_str()}] {msg}\n"
    try:
        _rotate_if_needed()
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass
    print(line, end="", flush=True)


def _rotate_if_needed():
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > WATCHDOG_LOG_MAX_BYTES:
            bak = LOG_FILE.with_suffix(".log.1")
            if bak.exists():
                bak.unlink()
            LOG_FILE.rename(bak)
    except OSError:
        pass


def write_heartbeat():
    try:
        WATCHER_DIR.mkdir(parents=True, exist_ok=True)
        ms = int(time.time() * 1000) % 1000
        ts = _now_str() + "." + str(ms).zfill(3)
        tmp = HEARTBEAT_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(ts)
        tmp.replace(HEARTBEAT_FILE)
    except OSError:
        pass


def is_process_alive(pid):
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
    try:
        mtime = os.path.getmtime(HB_FILE)
        return (time.time() - mtime) < STALE_SECONDS
    except OSError:
        return False


def get_watcher_pid():
    """Read the watcher PID from .watcher.lock (written by watcher.ps1)."""
    try:
        raw = LOCK_FILE.read_text("utf-8").strip()
        return int(raw) if raw.isdigit() else None
    except (OSError, ValueError):
        return None


def is_restarter_alive():
    """Check if the last launched restarter process is still running."""
    global _restarter_pid
    if _restarter_pid is None:
        return False
    if is_process_alive(_restarter_pid):
        return True
    _restarter_pid = None
    return False


def is_supervisor_active():
    """True if bridge_supervisor is running (heartbeat fresh <60s).

    When the supervisor is managing the bridge, the watchdog must NOT
    resurrect agents/watchers on its own — that fights the supervisor's
    reap/revive and causes the agent restart-loop (supervisor spawns,
    watchdog respawns, supervisor reaps...). Watchdog becomes fallback-only
    (covers the case where the supervisor itself is dead).
    """
    try:
        hb = WATCHER_DIR / ".supervisor_heartbeat"
        return (time.time() - hb.stat().st_mtime) < 60
    except OSError:
        return False


def is_maintenance_locked():
    """Check if maintenance lock exists and hasn't expired (TTL default 1800s)."""
    try:
        if not MAINTENANCE_LOCK.exists():
            return False
        raw = MAINTENANCE_LOCK.read_text("utf-8")
        lock = json.loads(raw)
        ttl = lock.get("ttl", 1800)
        started = datetime.datetime.strptime(lock["started_at"], "%Y-%m-%d %H:%M:%S")
        age = (datetime.datetime.now() - started).total_seconds()
        if age >= ttl:
            log(f"[MAINT] Maintenance lock expired ({age:.0f}s >= {ttl}s) — ignoring")
            MAINTENANCE_LOCK.unlink(missing_ok=True)
            return False
        log(f"[MAINT] Maintenance lock ACTIVE (age={age:.0f}s, reason={lock.get('reason','?')}) — skipping recovery")
        return True
    except (json.JSONDecodeError, KeyError, OSError):
        try:
            MAINTENANCE_LOCK.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def launch_restarter():
    global _restarter_pid
    if is_supervisor_active():
        log("[WATCHDOG] supervisor 存活中 — 交由 supervisor 接管，跳过 watcher 重启")
        return
    if is_maintenance_locked():
        log("[WATCHDOG] Maintenance lock active — skipping watcher restart")
        return
    if is_restarter_alive():
        log(f"[WATCHDOG] Restarter PID={_restarter_pid} still running — skipping (prevents process accumulation)")
        return
    log("[WATCHDOG] Watcher heartbeat stale - initiating restart")
    try:
        if LOCK_FILE.exists():
            LOCK_FILE.unlink()
            log("  Removed stale .watcher.lock")
    except OSError as e:
        log(f"  Could not remove lock: {e}")
    old_watcher_pid = get_watcher_pid()
    old_pid_str = str(old_watcher_pid) if old_watcher_pid else "0"
    log(f"  Old watcher PID from lock: {old_pid_str}")
    if RESTARTER.exists():
        try:
            proc = subprocess.Popen(
                ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                 "-File", str(RESTARTER), "-OldPID", old_pid_str, "-WatcherPath", str(WATCHER_PS1)],
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
            _restarter_pid = proc.pid
            log(f"  Launched restarter PID={proc.pid} (old_watcher={old_pid_str})")
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
    if is_supervisor_active():
        log("[WATCHDOG] supervisor 存活中 — 交由 supervisor 接管，跳过 agent 重启")
        return None
    if is_maintenance_locked():
        log("[WATCHDOG] Maintenance lock active — skipping bridge_agent restart")
        return None
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


def cleanup_zombie_processes():
    """Kill all stale bridge processes (watcher/workers/restarters) on startup.

    Reads PIDs from .lock files in watcher/ and cluster/*/ directories.
    This prevents process accumulation from previous buggy watchdog cycles
    where restarters launched without killing old watchers (OldPID=0).
    """
    import ctypes
    killed = 0
    pids_seen = set()

    # Collect PIDs from all lock files
    lock_files = [LOCK_FILE]  # watcher/.watcher.lock
    try:
        for d in WATCHER_DIR.iterdir():
            if d.is_dir():
                lf = d / ".lock"
                if lf.exists():
                    lock_files.append(lf)
    except OSError:
        pass
    try:
        cluster_dir = SCRIPT_DIR / "cluster"
        if cluster_dir.exists():
            for d in cluster_dir.iterdir():
                if d.is_dir():
                    for lock_name in [".watcher.lock", ".lock"]:
                        lf = d / lock_name
                        if lf.exists():
                            lock_files.append(lf)
    except OSError:
        pass

    for lf in lock_files:
        try:
            raw = lf.read_text("utf-8").strip()
            if raw.isdigit():
                pid = int(raw)
                if pid in pids_seen or pid == os.getpid():
                    continue
                pids_seen.add(pid)
                # Try to kill
                kernel32 = ctypes.windll.kernel32
                PROCESS_TERMINATE = 0x0001
                handle = kernel32.OpenProcess(PROCESS_TERMINATE, False, pid)
                if handle:
                    kernel32.TerminateProcess(handle, 1)
                    kernel32.CloseHandle(handle)
                    killed += 1
                    log(f"  Killed zombie PID={pid} (from {lf.parent.name}/{lf.name})")
        except (OSError, ValueError):
            pass

    # Clean up all lock files after killing
    for lf in lock_files:
        try:
            lf.unlink(missing_ok=True)
        except OSError:
            pass

    if killed > 0:
        log(f"[CLEANUP] Killed {killed} zombie bridge processes on startup")
    else:
        log("[CLEANUP] No zombie processes found")


def main():
    parser = argparse.ArgumentParser(description="bridge_agent watchdog subprocess")
    parser.add_argument("--parent-pid", type=int, required=True, help="PID of the parent bridge_agent process")
    parser.add_argument("--verbose", action="store_true", help="Log periodic alive pings")
    args = parser.parse_args()
    parent_pid = args.parent_pid
    verbose = args.verbose
    log(f"=== Watchdog started (parent PID={parent_pid}) ===")
    log(f"  Script dir:  {SCRIPT_DIR}")
    log(f"  Watcher dir: {WATCHER_DIR}")
    log(f"  Log file:    {LOG_FILE}")

    # Clean up zombie processes from previous buggy watchdog cycles
    cleanup_zombie_processes()

    # Hot-reload: exit if this script file was modified (bridge_agent will respawn with new code)
    _script_mtime_at_start = Path(__file__).resolve().stat().st_mtime

    restart_count = 0
    last_watcher_recovery = 0
    last_parent_check = 0
    last_heartbeat = 0
    last_bridge_recovery = 0
    last_alive_log = 0
    watcher_was_alive = is_watcher_alive()
    parent_was_alive = is_process_alive(parent_pid)
    log(f"  Initial state: watcher_alive={watcher_was_alive} parent_alive={parent_was_alive}")
    while True:
        try:
            # Hot-reload: exit if script file was modified (bridge_agent respawns with new code)
            try:
                current_mtime = Path(__file__).resolve().stat().st_mtime
                if current_mtime != _script_mtime_at_start:
                    log(f"[HOT-RELOAD] Script file modified (was {_script_mtime_at_start}, now {current_mtime}) — exiting for respawn")
                    sys.exit(0)
            except OSError:
                pass

            now = time.monotonic()
            if now - last_heartbeat >= HEARTBEAT_INTERVAL:
                write_heartbeat()
                last_heartbeat = now
            if verbose and now - last_alive_log >= 60:
                last_alive_log = now
                log(f"[ALIVE] parent_alive={is_process_alive(parent_pid)} watcher_alive={is_watcher_alive()} pid={os.getpid()}")
            if now - last_parent_check >= PARENT_CHECK_INTERVAL:
                last_parent_check = now
                alive = is_process_alive(parent_pid)
                if not alive:
                    log(f"[WATCHDOG] Parent PID={parent_pid} is dead")
                    if now - last_bridge_recovery >= RESTART_MAX_BACKOFF + 5:
                        restart_count += 1
                        backoff = min(RESTART_BACKOFF_BASE ** restart_count, RESTART_MAX_BACKOFF)
                        log(f"  Recovery attempt #{restart_count} (backoff={backoff}s)")
                        new_pid = launch_bridge_agent()
                        if new_pid:
                            parent_pid = new_pid
                            last_bridge_recovery = now
                            restart_count = 0
                        else:
                            time.sleep(backoff)
                            continue
                    else:
                        time.sleep(1)
                        continue
                else:
                    if restart_count > 0:
                        restart_count = 0
            if now - last_watcher_recovery >= CHECK_INTERVAL:
                last_watcher_recovery = now
                if not is_watcher_alive():
                    launch_restarter()
            time.sleep(1)
        except Exception as e:
            import traceback
            tb = traceback.format_exc()
            log(f"[FATAL] Unhandled exception in main loop: {e}\n{tb}")
            time.sleep(5)


if __name__ == "__main__":
    main()
