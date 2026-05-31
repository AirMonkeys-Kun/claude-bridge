import os, json

USER = r"C:\Users\wsx"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
CLAUDE_DATA = PKG + r"\LocalCache\Local\Claude-3p"
SESSIONS = CLAUDE_DATA + r"\local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001"
WSL_PATH = "\\\\wsl.localhost\\ubuntu\\home\\yck"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\fix_result2.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Fix ALL session files + Find global config ===")

# Step 1: Fix ALL session files
log("\n--- Step 1: Fix ALL session files with WSL path ---")
fixed_count = 0
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith(".json"):
            fp = os.path.join(root, f)
            try:
                with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                    content = fh.read(100000)
                if WSL_PATH in content:
                    log(f"WSL found: {os.path.relpath(fp, CLAUDE_DATA)}")
                    # Read as JSON and modify
                    with open(fp, "r", encoding="utf-8") as fh:
                        data = json.load(fh)
                    if isinstance(data, dict) and "userSelectedFolders" in data:
                        if WSL_PATH in data["userSelectedFolders"]:
                            data["userSelectedFolders"].remove(WSL_PATH)
                            # Backup
                            bak = fp + ".backup2"
                            if not os.path.exists(bak):
                                os.rename(fp, bak) if os.path.exists(fp) else None
                            with open(fp, "w", encoding="utf-8") as fh:
                                json.dump(data, fh, indent=2, ensure_ascii=False)
                            log(f"  -> FIXED!")
                            fixed_count += 1
                    elif isinstance(data, list):
                        # Could be a list of tasks or something
                        for item in data:
                            if isinstance(item, dict) and "userSelectedFolders" in item:
                                if WSL_PATH in item["userSelectedFolders"]:
                                    item["userSelectedFolders"].remove(WSL_PATH)
                                    with open(fp, "w", encoding="utf-8") as fh:
                                        json.dump(data, fh, indent=2, ensure_ascii=False)
                                    log(f"  -> FIXED! (list item)")
                                    fixed_count += 1
            except Exception as e:
                log(f"  Error with {f}: {e}")

log(f"\nFixed {fixed_count} files total")

# Step 2: Search for WHERE the global config lives
log("\n--- Step 2: Find the global persistent config ---")
# Check SharedStorage
shared = os.path.join(CLAUDE_DATA, "SharedStorage")
if os.path.isfile(shared):
    log(f"\nSharedStorage exists: {shared} ({os.path.getsize(shared)} bytes)")
    try:
        with open(shared, "rb") as f:
            data = f.read()
        # Look for WSL path in binary
        if b"wsl" in data.lower():
            idx = data.lower().find(b"wsl")
            log(f"  WSL found at byte {idx}")
            log(f"  Context: {data[max(0,idx-30):idx+80]}")
    except:
        log("  Cannot read")

# Check for any file named "storage", "store", "db", or "state"
similar_files = []
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
        except:
            continue
        kw = any(k in f.lower() for k in ["storage", "store", "state", "config", "setting", "pref", "db", "data"])
        if kw or sz > 1000000:
            similar_files.append(os.path.relpath(fp, CLAUDE_DATA))

log(f"\nOther important files:")
for sf in sorted(similar_files):
    sfp = os.path.join(CLAUDE_DATA, sf)
    sz = os.path.getsize(sfp)
    log(f"  {sf} ({sz:,} bytes)")

# Step 3: Check LevelDB files for workspace config
log("\n--- Step 3: Search LevelDB files ---")
leveldb_dirs = []
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith((".ldb", ".log", ".db", ".sqlite")):
            fp = os.path.join(root, f)
            rel = os.path.relpath(os.path.dirname(fp), CLAUDE_DATA)
            if rel not in leveldb_dirs:
                leveldb_dirs.append(rel)
                log(f"  LevelDB/SQLite in: {rel}")

# Step 4: Check files in the .claude directory for workspace config
claude_dir = USER + r"\.claude\projects"
log(f"\n--- Step 4: Check projects in .claude ---")
if os.path.isdir(claude_dir):
    for root, dirs, files in os.walk(claude_dir):
        for f in files:
            if f.endswith(".json"):
                fp = os.path.join(root, f)
                try:
                    with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                        content = fh.read(50000)
                    if "userSelectedFolders" in content or ("folder" in content.lower() and "wsl" in content.lower()):
                        log(f"  Found in {fp}: {content[:200]}")
                except:
                    pass
else:
    log(f"  {claude_dir} NOT FOUND")

log(f"\n=== Done ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
