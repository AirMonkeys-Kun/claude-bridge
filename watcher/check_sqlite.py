import os, sqlite3, json

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
WSL = "wsl.localhost"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\sqlite_check.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Check SQLite databases for workspace config ===")

dbs = [
    "DIPS",
    "SharedStorage",
    "WebStorage/QuotaManager",
    "Partitions/cowork-file-preview/SharedStorage",
]

for db_name in dbs:
    fp = os.path.join(CLAUDE_DATA, db_name.replace("/", "\\"))
    if not os.path.exists(fp):
        log(f"\n{db_name}: NOT FOUND")
        continue

    sz = os.path.getsize(fp)
    log(f"\n--- {db_name} ({sz:,} bytes) ---")

    try:
        conn = sqlite3.connect(fp)
        cursor = conn.cursor()

        # Get all tables
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = cursor.fetchall()
        log(f"Tables: {[t[0] for t in tables]}")

        for (table_name,) in tables:
            try:
                cursor.execute(f"SELECT * FROM \"{table_name}\" LIMIT 20")
                rows = cursor.fetchall()
                col_names = [desc[0] for desc in cursor.description]
                log(f"  Table '{table_name}': columns={col_names}, rows={len(rows)}")

                for row in rows:
                    row_str = json.dumps(row, ensure_ascii=False)[:500]
                    if WSL in row_str.lower():
                        log(f"    >>> WSL FOUND: {row_str}")

                    # Also check for folder-related content
                    for cell in row:
                        if isinstance(cell, str) and ("folder" in cell.lower() or "workspace" in cell.lower() or "mount" in cell.lower()):
                            log(f"    >>> INTERESTING: {cell[:200]}")

                # Count total rows
                cursor.execute(f"SELECT COUNT(*) FROM \"{table_name}\"")
                count = cursor.fetchone()[0]
                if count > 20:
                    log(f"  ... ({count - 20} more rows)")

            except Exception as e:
                log(f"  Error reading table '{table_name}': {e}")

        conn.close()
    except Exception as e:
        log(f"  Error opening database: {e}")

log("\n=== Done ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
