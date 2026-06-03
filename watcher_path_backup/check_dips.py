import os, sqlite3, shutil

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
TEMP = r"C:\Users\wsx\Desktop\claude-bridge\watcher"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\dips_data.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== DIPS & WebStorage detailed dump ===")

for src_path, label in [
    (os.path.join(CLAUDE_DATA, "DIPS"), "DIPS"),
    (os.path.join(CLAUDE_DATA, "WebStorage", "QuotaManager"), "WebStorage"),
    (os.path.join(CLAUDE_DATA, "SharedStorage"), "SharedStorage"),
    (os.path.join(CLAUDE_DATA, "Partitions", "cowork-file-preview", "SharedStorage"), "CoworkPartition"),
]:
    dst = os.path.join(TEMP, f"_{label}.sqlite")
    log(f"\n--- {label} ---")
    try:
        shutil.copy2(src_path, dst)
        conn = sqlite3.connect(dst)
        conn.row_factory = sqlite3.Row
        c = conn.cursor()

        c.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [t[0] for t in c.fetchall()]

        for table in tables:
            log(f"\n  Table: {table}")
            c.execute(f"SELECT * FROM \"{table}\"")
            rows = c.fetchall()
            for row in rows:
                d = dict(row)
                log(f"    Row: {json.dumps(d, ensure_ascii=False)}")

        conn.close()
        os.remove(dst)
    except Exception as e:
        log(f"  Error: {e}")

# Full VHDX search for WSL (remaining bytes beyond 100MB)
log("\n\n--- VHDX full binary search for WSL ---")
vhdx = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\vm_bundles\claudevm.bundle\sessiondata.vhdx"
WSL_B = b"wsl.localhost"
try:
    with open(vhdx, "rb") as f:
        import struct
        # VHDX has 1MB blocks; scan block-by-block
        f.seek(0, 2)
        total = f.tell()
        log(f"VHDX total size: {total:,} bytes")

        # Start from 100MB where we left off
        start_pos = 100 * 1024 * 1024
        f.seek(start_pos)

        block_size = 1024 * 1024
        found = False
        for offset in range(start_pos, total, block_size):
            f.seek(offset)
            chunk = f.read(block_size)
            if WSL_B in chunk:
                idx = chunk.index(WSL_B)
                abs_offset = offset + idx
                log(f">>> WSL found at offset {abs_offset:,} (block {abs_offset // block_size})")

                # Get context
                start_ctx = max(0, abs_offset - 128)
                f.seek(start_ctx)
                ctx = f.read(512)
                log(f"    Context ({len(ctx)} bytes):")
                # Filter printable chars
                printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
                log(f"    {printable}")

                found = True
                break

        if not found:
            log("WSL path NOT found in rest of VHDX")
            log("It may be in the first 100MB (scanned earlier)")

except Exception as e:
    log(f"VHDX search error: {e}")

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
