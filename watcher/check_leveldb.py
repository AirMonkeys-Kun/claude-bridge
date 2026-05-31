import os

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
WSL = b"wsl.localhost"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\leveldb_check.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Check LevelDB/Local Storage for WSL path ===")

# Scan all LevelDB files for WSL path
leveldb_patterns = [
    "Local Storage\\leveldb",
    "Session Storage",
    "IndexedDB",
]

found_entries = []

for pattern in leveldb_patterns:
    base = os.path.join(CLAUDE_DATA, pattern)
    if not os.path.isdir(base):
        log(f"\n{pattern}: NOT FOUND")
        continue
    log(f"\n{pattern}:")
    for f in sorted(os.listdir(base)):
        fp = os.path.join(base, f)
        if os.path.isfile(fp):
            try:
                with open(fp, "rb") as fh:
                    data = fh.read()
                if WSL in data:
                    # Find context
                    idx = data.index(WSL)
                    ctx = data[max(0,idx-50):idx+100]
                    log(f"  >>> WSL FOUND in {f} (size={len(data)})")
                    log(f"      Context: {ctx}")
                    found_entries.append({"file": f"{pattern}\\{f}", "context": str(ctx[:200])})
                else:
                    # Also check for "userSelectedFolders" key
                    if b"userSelectedFolders" in data:
                        idx2 = data.index(b"userSelectedFolders")
                        ctx2 = data[max(0,idx2-30):idx2+200]
                        log(f"  *** userSelectedFolders in {f}")
                        log(f"      {ctx2}")
            except:
                pass

if not found_entries:
    log("\nWSL path NOT found in any LevelDB file - good! Only in session JSON.")

# Also search in ALL remaining binary files under Claude-3p
log("\n--- Broad binary search in Claude-3p ---")
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith((".ldb", ".log", ".db", ".sqlite")):
            fp = os.path.join(root, f)
            try:
                with open(fp, "rb") as fh:
                    data = fh.read(500000)
                if WSL in data:
                    rel = os.path.relpath(fp, CLAUDE_DATA)
                    log(f"WSL in: {rel}")
            except:
                pass

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"\nResult: {LOG}")
