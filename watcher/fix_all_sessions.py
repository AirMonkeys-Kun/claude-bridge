import os, json, glob, shutil

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
SESSIONS_DIR = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\fix_all_result.txt"
WSL_PATH = r"\\wsl.localhost\ubuntu\home\yck"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Fix ALL session files: remove WSL from userSelectedFolders ===")

# 1. Find all session JSON files
session_files = []
for root, dirs, files in os.walk(SESSIONS_DIR):
    for f in files:
        if f.endswith(".json") and not f.endswith(".backup"):
            fp = os.path.join(root, f)
            session_files.append(fp)

log(f"\nFound {len(session_files)} JSON files to check")

# 2. Find scheduled-tasks.json specifically
scheduled_tasks = os.path.join(SESSIONS_DIR, "scheduled-tasks.json")
if os.path.exists(scheduled_tasks):
    session_files.append(scheduled_tasks)
    log(f"Added scheduled-tasks.json to check list")

# 3. Also search for any other files with userSelectedFolders
log("\n--- Scanning for ALL files containing userSelectedFolders ---")
extra_files = []
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        if fp in session_files:
            continue
        try:
            sz = os.path.getsize(fp)
            if sz > 5000000:  # skip > 5MB
                continue
            with open(fp, "rb") as fh:
                data = fh.read(min(sz, 200000))
            if b"userSelectedFolders" in data:
                extra_files.append(fp)
                rel = os.path.relpath(fp, CLAUDE_DATA)
                log(f"  EXTRA: {rel} ({sz:,} bytes)")
        except:
            pass

# 4. Process each file
log("\n--- Processing each file ---")
fixed_count = 0
wsl_found_count = 0
no_change_count = 0

for fp in session_files + extra_files:
    rel = os.path.relpath(fp, CLAUDE_DATA)
    try:
        with open(fp, "r", encoding="utf-8") as fh:
            data = fh.read()

        obj = json.loads(data)

        # Handle both dict (single object) and list (array of objects)
        objects_to_check = []
        if isinstance(obj, dict):
            objects_to_check = [(obj, "")]
        elif isinstance(obj, list):
            objects_to_check = [(item, f"[{i}]") for i, item in enumerate(obj)]

        found_wsl = False
        for target_obj, prefix in objects_to_check:
            if "userSelectedFolders" in target_obj:
                folders = target_obj["userSelectedFolders"]
                if WSL_PATH in folders:
                    found_wsl = True
                    folders.remove(WSL_PATH)
                    target_obj["userSelectedFolders"] = folders
                    log(f"  {rel}{prefix}: REMOVED WSL. Remaining: {len(folders)} folders")

        if found_wsl:
            # Create backup
            backup = fp + ".backup"
            if not os.path.exists(backup):
                shutil.copy2(fp, backup)
                log(f"  Backup created: {backup}")

            with open(fp, "w", encoding="utf-8") as fh:
                json.dump(obj, fh, ensure_ascii=False, indent=2)
            fixed_count += 1
            log(f"  >>> FIXED: {rel}")
        else:
            no_change_count += 1
            log(f"  {rel}: no WSL path found (skipped)")

    except Exception as e:
        log(f"  ERROR {rel}: {e}")

log(f"\n=== Summary ===")
log(f"  Files fixed: {fixed_count}")
log(f"  No change: {no_change_count}")
log(f"  Total files found with userSelectedFolders: {fixed_count + no_change_count}")

# Verify: re-scan for WSL
log(f"\n--- Verification scan ---")
wsl_still_present = 0
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            if sz > 5000000:
                continue
            with open(fp, "rb") as fh:
                data = fh.read(min(sz, 200000))
            if WSL_PATH.encode("utf-8") in data:
                rel = os.path.relpath(fp, CLAUDE_DATA)
                log(f"  STILL HAS WSL: {rel}")
                wsl_still_present += 1
        except:
            pass

if wsl_still_present == 0:
    log(f"\n>>> SUCCESS: WSL path removed from all accessible files!")
else:
    log(f"\n>>> WARNING: {wsl_still_present} file(s) still contain WSL path")

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
