#!/usr/bin/env python3
"""
bridge_doorbell_listener.py - Sandbox-side doorbell listener

Runs INSIDE the bwrap sandbox. Connects to the Unix socket exposed by
vsock_doorbell_daemon. On receiving "DING\n":
1. Forces a stat on the bridge queue file to bust FUSE attribute cache
2. Optionally signals the bridge watcher that new data is available

This eliminates the 200-600ms FUSE entry_timeout delay — when the host
writes to the 9P queue and sends a vsock doorbell, this listener picks
up the signal within microseconds and forces an immediate file stat.

Architecture:
  Host (PowerShell) → Hyper-V vsock port 9999 → daemon (rootfs)
  → Unix socket /tmp/bridge-doorbell.sock → THIS LISTENER (sandbox)
  → stat(queue_file) → bridge watcher sees change instantly
"""

import socket
import os
import sys
import time
import signal
import select

UNIX_SOCK_PATH = "/tmp/bridge-doorbell.sock"

# Paths to watch (9P mounted files that need FUSE cache busting)
# These are the files the bridge watcher monitors via FSW/inotify
WATCH_PATHS = [
    "/mnt/claude-bridge/cluster/.pipe_master_queue.json",
    "/mnt/claude-bridge/cluster/.pipe_batch_result.json",
]

def bust_fuse_cache(paths):
    """Force a stat() on each path to bust the FUSE attribute cache.

    The FUSE 9P mount uses entry_timeout=1.0 (1 second) by default.
    This means stat() results are cached for up to 1 second. When the
    host writes a new file, the guest won't see the updated mtime/size
    until the cache expires.

    By calling os.stat() here (triggered by the doorbell), we force
    the FUSE client to revalidate the attributes with the 9P server.
    This makes the change visible to the bridge watcher immediately
    instead of waiting up to 1 second.
    """
    for path in paths:
        try:
            os.stat(path)
        except OSError:
            pass  # File might not exist yet, that's OK

def main():
    print(f"[doorbell-listener] Connecting to {UNIX_SOCK_PATH}", flush=True)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    # Retry connection — daemon might not be ready yet
    for attempt in range(30):
        try:
            sock.connect(UNIX_SOCK_PATH)
            print(f"[doorbell-listener] Connected (attempt {attempt+1})", flush=True)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if attempt == 0:
                print(f"[doorbell-listener] Daemon not ready, retrying...", flush=True)
            time.sleep(0.5)
    else:
        print("[doorbell-listener] Failed to connect — doorbell not available", file=sys.stderr, flush=True)
        # Exit gracefully — bridge works without doorbell (just slower)
        sys.exit(0)

    sock.setblocking(False)

    print(f"[doorbell-listener] Ready. Watching {len(WATCH_PATHS)} paths.", flush=True)

    ring_count = 0
    while True:
        try:
            readable, _, _ = select.select([sock], [], [], 10.0)
        except (InterruptedError, KeyboardInterrupt):
            break

        if sock in readable:
            try:
                data = sock.recv(1024)
                if not data:
                    print("[doorbell-listener] Daemon disconnected — exiting", flush=True)
                    break

                ring_count += 1
                # Immediately bust FUSE cache on all watched paths
                bust_fuse_cache(WATCH_PATHS)

                if ring_count <= 5 or ring_count % 100 == 0:
                    print(f"[doorbell-listener] DING #{ring_count} — cache busted", flush=True)

            except BlockingIOError:
                pass
            except Exception as e:
                print(f"[doorbell-listener] Error: {e}", file=sys.stderr, flush=True)
                break

    sock.close()
    print(f"[doorbell-listener] Stopped ({ring_count} rings)", flush=True)

if __name__ == '__main__':
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))
    main()
