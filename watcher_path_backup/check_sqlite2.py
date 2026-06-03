import os, sqlite3, json, shutil

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
TEMP = r"C:\Users\wsx\Desktop\claude-bridge\watcher"
WSL = "wsl.localhost"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\sqlite_check2.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Check SQLite DBs by copying first (avoid lock) ===")

dbs = [
    ("DIPS", "DIPS"),
    ("SharedStorage", "SharedStorage"),
    ("WebStorage/QuotaManager", "WebStorage_QuotaManager"),
    ("Partitions/cowork-file-preview/SharedStorage", "Partition_SharedStorage"),
]

for db_rel, copy_name in dbs:
    src = os.path.join(CLAUDE_DATA, db_rel.replace("/", "\\"))
    dst = os.path.join(TEMP, f"_{copy_name}.sqlite")

    log(f"\n--- {db_rel} ---")
    if not os.path.exists(src):
        log("  NOT FOUND")
        continue

    log(f"  Original size: {os.path.getsize(src):,} bytes")

    try:
        # Copy the file (this bypasses SQLite lock)
        shutil.copy2(src, dst)
        log(f"  Copied to: {copy_name}.sqlite")

        # Open the copy read-only
        conn = sqlite3.connect(dst)
        conn.execute("PRAGMA query_only = ON;")
        cursor = conn.cursor()

        # Get tables
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = [t[0] for t in cursor.fetchall()]
        log(f"  Tables: {tables}")

        for table in tables:
            try:
                cursor.execute(f"PRAGMA table_info(\"{table}\")")
                cols = [c[1] for c in cursor.fetchall()]
                log(f"  Table '{table}': columns={cols}")

                cursor.execute(f"SELECT * FROM \"{table}\"")
                rows = cursor.fetchall()
                log(f"  Rows: {len(rows)}")

                for row in rows[:30]:
                    row_str = json.dumps(row, ensure_ascii=False)[:600]
                    if WSL in row_str.lower():
                        log(f"    >>> WSL FOUND: {row_str}")

                    # Check for folk, workspace, mount
                    for cell in row:
                        if isinstance(cell, str):
                            cl = cell.lower()
                            if any(k in cl for k in ["folder", "workspace", "mount", "\\wsl", "userselected"]):
                                log(f"    >>> KEY VALUE: {cell[:300]}")

                if len(rows) > 30:
                    log(f"    ... and {len(rows) - 30} more rows")

            except Exception as e:
                log(f"  Error reading table '{table}': {e}")

        conn.close()
        os.remove(dst)

    except Exception as e:
        log(f"  Error: {e}")

log("\n=== Done ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
