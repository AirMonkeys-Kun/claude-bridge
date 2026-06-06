"""
config.py — Configuration and shared constants for bridge_agent.
"""
import os
import threading
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────
DEFAULT_WATCHER_DIR = r"D:\zebbingo\tools\claude-bridge\watcher"
DEFAULT_CLUSTER_DIR = r"D:\zebbingo\tools\claude-bridge\cluster"

WATCHER_DIR = Path(os.environ.get("BRIDGE_WATCHER_DIR", DEFAULT_WATCHER_DIR))
CLUSTER_DIR = Path(os.environ.get("BRIDGE_CLUSTER_DIR", DEFAULT_CLUSTER_DIR))
QUEUE_FILE = WATCHER_DIR / "queue.txt"
POOL_FILE = CLUSTER_DIR / ".worker_pool.json"
RESULT_DIR = WATCHER_DIR

# ── Network ────────────────────────────────────────────────────────────
DEFAULT_PORT = 19850

# ── Timing ─────────────────────────────────────────────────────────────
POLL_INTERVAL = 0.02          # 20ms between result file checks
QUEUE_WRITE_RETRIES = 3
QUEUE_WRITE_BACKOFF = 0.1
MAX_CONCURRENT = 5

# ── Pipe dispatch ──────────────────────────────────────────────────────
PIPE_RETRY_ATTEMPTS = 3       # retry pipe dispatch before falling to queue
PIPE_RETRY_DELAY = 0.05       # 50ms between retries
PIPE_RESPONSE_BUFFER = 4096   # max response bytes from Named Pipe
PIPE_TIMEOUT_MS = 150         # ms to wait for CallNamedPipe (0=instant, may skip busy workers)

# ── Worker type mapping ────────────────────────────────────────────────
TYPE_MAP = {
    "wsl": "wsl", "user": "user", "file": "file",
    "process": "process", "system": "system",
}

# ── Shared state ───────────────────────────────────────────────────────
queue_serial = threading.Lock()       # serializes queue.txt commands
active_connections = 0
active_lock = threading.Lock()
_worker_pool = None
_pool_load_time = 0
_pool_lock = threading.Lock()
