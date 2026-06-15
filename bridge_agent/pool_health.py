"""
pool_health.py -- Lightweight worker pool health monitor for bridge_agent.

V3.5: Runs periodically to detect dead workers in the pool file and trigger
replenish via the guardian/watcher. Bridges the gap between the PS guardian
and Python bridge_agent's pool cache.

Imports are optional -- if not available, the health check silently returns.
"""

import json
import logging
import os
import time
from pathlib import Path

_logger = logging.getLogger(__name__)

# Expected worker plan (mirrors guardian_v3.ps1 replenish + worker_factory.ps1)
_EXPECTED_PLAN = {
    "generic": 6, "file": 4, "process": 2, "system": 2, "user": 1
    # wsl removed V3.5: wsl_pool in bridge_agent handles all wsl commands
}


def _read_pool(pool_path):
    """Read worker pool JSON. Returns None on failure."""
    try:
        with open(pool_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def _is_pid_alive(pid):
    """Check if a Windows PID is alive (platform-specific)."""
    if os.name != "nt":
        return True  # can't check on non-Windows
    import ctypes
    import ctypes.wintypes
    SYNCHRONIZE = 0x100000
    try:
        handle = ctypes.windll.kernel32.OpenProcess(SYNCHRONIZE, False, pid)
        if handle:
            ctypes.windll.kernel32.CloseHandle(handle)
            return True
        return False
    except OSError:
        return False


def check_pool_health(pool_path=None):
    """
    Read pool file, count alive/dead workers, detect gaps vs expected plan.
    Returns dict with health summary. If gaps detected, writes a marker file
    that the guardian's replenish picks up next cycle.
    """
    if pool_path is None:
        base = Path(__file__).resolve().parent.parent
        pool_path = base / "cluster" / ".worker_pool.json"

    pool = _read_pool(pool_path)
    if not pool or "workers" not in pool:
        return {"error": "pool_unreadable", "workers_total": 0}

    workers = pool["workers"]
    alive = 0
    dead_ids = []
    present_ids = set()

    for w in workers:
        present_ids.add(w["id"])
        if w.get("pid") and _is_pid_alive(w["pid"]):
            alive += 1
        else:
            dead_ids.append(w["id"])

    # Check for gaps vs expected plan
    gaps = []
    for wtype, count in _EXPECTED_PLAN.items():
        for i in range(1, count + 1):
            wid = f"{wtype}_{i}"
            if wid not in present_ids:
                gaps.append(wid)

    result = {
        "workers_total": len(workers),
        "workers_alive": alive,
        "workers_dead": len(dead_ids),
        "dead_worker_ids": dead_ids,
        "gaps_vs_expected": gaps,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }

    if gaps:
        _logger.warning(
            "Pool gaps detected: %s (total_dead=%d, alive=%d/%d)",
            gaps, len(dead_ids), alive, len(workers)
        )

    return result


def periodic_health_loop(interval=60, pool_path=None):
    """
    Blocking loop: check pool health every `interval` seconds.
    Designed to run in a daemon thread alongside bridge_agent's TCP server.
    """
    while True:
        try:
            result = check_pool_health(pool_path)
            if result.get("gaps_vs_expected") or result.get("workers_dead", 0) > 0:
                _logger.info("Pool health: %s", result)
        except Exception as e:
            _logger.error("Pool health check failed: %s", e)
        time.sleep(interval)
