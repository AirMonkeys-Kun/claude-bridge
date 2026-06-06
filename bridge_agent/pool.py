"""
pool.py — Worker pool loading and worker discovery for bridge_agent.
"""
import ctypes
import json
import os
import sys
import time

from .config import (
    POOL_FILE, TYPE_MAP, _worker_pool, _pool_load_time, _pool_lock,
)


def is_pid_alive(pid):
    """Check if a process is alive. Works on Windows and Linux."""
    if sys.platform == "win32":
        kernel32 = ctypes.windll.kernel32
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259

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


def load_worker_pool(force=False):
    """Load and cache .worker_pool.json (30s TTL)."""
    import bridge_agent.config as cfg
    now = time.monotonic()
    with _pool_lock:
        if not force and cfg._worker_pool and (now - cfg._pool_load_time) < 30:
            return cfg._worker_pool
        pool_data = _read_json(POOL_FILE)
        if pool_data and "workers" in pool_data:
            cfg._worker_pool = pool_data
            cfg._pool_load_time = now
            return cfg._worker_pool
    return None


def find_all_workers(cmd_type):
    """Find ALL alive workers for the given command type. Returns list."""
    pool = load_worker_pool()
    if not pool or not pool.get("workers"):
        return []

    target = TYPE_MAP.get(cmd_type, "generic")
    candidates = [w for w in pool["workers"] if w.get("type") == target]
    if not candidates and target != "generic":
        candidates = [w for w in pool["workers"] if w.get("type") == "generic"]

    return [w for w in candidates if is_pid_alive(w["pid"])]


def _read_json(path):
    """Read a JSON file with UTF-8 BOM tolerance."""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
