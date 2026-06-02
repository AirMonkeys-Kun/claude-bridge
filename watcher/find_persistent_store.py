import os, json, time

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
WSL_BYTES = b"wsl.localhost"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\persistent_search.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Search for persistent userSelectedFolders storage ===")

# 1. Check spaces.json
log("\n--- 1. spaces.json ---")
spaces = os.path.join(CLAUDE_DATA, r"local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001\spaces.json")
if os.path.exists(spaces):
    with open(spaces, "r", encoding="utf-8") as f:
        log(f"Content ({os.path.getsize(spaces)} bytes):\n{f.read()[:2000]}")

# 2. Search for recently modified files (last 10 min) that CONTAIN WSL path
log("\n--- 2. Recently modified files with WSL content ---")
now = time.time()
ten_min_ago = now - 600

for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        try:
            mtime = os.path.getmtime(fp)
            if mtime > ten_min_ago:
                try:
                    sz = os.path.getsize(fp)
                    if sz < 10000000:
                        with open(fp, "rb") as fh:
                            content = fh.read(500000)
                        if WSL_BYTES in content:
                            rel = os.path.relpath(fp, CLAUDE_DATA)
                            log(f"  WSL in RECENT file: {rel} (modified: {time.strftime('%H:%M:%S', time.localtime(mtime))})")
                except:
                    pass
        except:
            pass

# 3. Check SharedStorage (write-ahead log may have keys)
log("\n--- 3. SharedStorage WAL check ---")
for name in ["SharedStorage", "SharedStorage-wal"]:
    fp = os.path.join(CLAUDE_DATA, name)
    if os.path.exists(fp):
        sz = os.path.getsize(fp)
        log(f"{name}: {sz:,} bytes")
        if sz > 0:
            with open(fp, "rb") as f:
                data = f.read(50000)
            if WSL_BYTES in data:
                idx = data.index(WSL_BYTES)
                log(f"  Contains WSL at offset {idx}")

# Also check partition SharedStorage
for name in ["SharedStorage", "SharedStorage-wal"]:
    fp = os.path.join(CLAUDE_DATA, "Partitions", "cowork-file-preview", name)
    if os.path.exists(fp):
        sz = os.path.getsize(fp)
        if sz > 0:
            with open(fp, "rb") as f:
                data = f.read(50000)
            if WSL_BYTES in data:
                log(f"Partition SharedStorage contains WSL")

# 4. Search for any SQLite databases
log("\n--- 4. SQLite databases ---")
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            if sz < 16:
                continue
            with open(fp, "rb") as fh:
                header = fh.read(16)
            if header[:16] == b'SQLite format 3\x00':
                rel = os.path.relpath(fp, CLAUDE_DATA)
                log(f"  SQLite: {rel} ({sz:,} bytes)")
        except:
            pass

# 5. Check Registry (software hive for MSIX packages)
log("\n--- 5. Package registry remnants ---")
registry_base = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
settings_dirs = [
    registry_base + r"\Settings",
    registry_base + r"\SystemAppData",
    registry_base + r"\LocalCache\Roaming\Microsoft",
]
for d in settings_dirs:
    if os.path.isdir(d):
        for root, dirs, files in os.walk(d):
            for f in files:
                fp = os.path.join(root, f)
                rel = os.path.relpath(fp, registry_base)
                try:
                    with open(fp, "rb") as fh:
                        data = fh.read(50000)
                    if WSL_BYTES in data:
                        log(f"  WSL in registry-like file: {rel}")
                except:
                    log(f"  {rel} ({os.path.getsize(fp)} bytes)")

# 6. Check the sessiondata.vhdx for any accessible metadata
log("\n--- 6. sessiondata.vhdx info ---")
vhdx = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\vm_bundles\claudevm.bundle\sessiondata.vhdx"
if os.path.exists(vhdx):
    log(f"sessiondata.vhdx: {os.path.getsize(vhdx):,} bytes")
    # Check header
    with open(vhdx, "rb") as f:
        header = f.read(512)
    # VHDX signature
    if header[:8] == b'vhdxfile':
        log("  Valid VHDX format")
        # Quick scan for WSL in VHDX
        with open(vhdx, "rb") as f:
            # Read at intervals to find WSL
            chunk_size = 1024 * 1024  # 1MB
            f.seek(0, 2)
            total = f.tell()
            f.seek(0)
            for pos in range(0, min(total, 100 * chunk_size), chunk_size):
                f.seek(pos)
                chunk = f.read(chunk_size)
                if WSL_BYTES in chunk:
                    idx = chunk.index(WSL_BYTES)
                    abs_offset = pos + idx
                    log(f"  >>> WSL found in VHDX at offset {abs_offset:,}")
                    # Get context
                    f.seek(max(0, abs_offset - 50))
                    ctx = f.read(200)
                    log(f"      Context: {ctx}")
                    break
    else:
        log(f"  Unknown format, header: {header[:32].hex()}")

log("\n=== Done ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
