import os, json, shutil

USER = r"C:\Users\wsx"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
CLAUDE_DATA = PKG + r"\LocalCache\Local\Claude-3p"
SESSION_BASE = CLAUDE_DATA + r"\local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001"

CURRENT = os.path.join(SESSION_BASE, "local_8108405e-cac5-481d-9ad7-a58b2452fc01.json")
WSL_PATH = "\\\\wsl.localhost\\ubuntu\\home\\yck"

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\fix_result.txt"

results = []

def log(msg):
    print(msg)
    results.append(msg)

log("=== Fix WSL Path from session config ===")
log(f"Target: {CURRENT}")
log(f"WSL path to remove: {WSL_PATH}")

# 1. Try to modify current session file
log("\n--- Step 1: Modify current session file ---")
if os.path.exists(CURRENT):
    try:
        # Backup
        backup = CURRENT + ".backup"
        shutil.copy2(CURRENT, backup)
        log(f"Backup created: {backup}")

        with open(CURRENT, "r", encoding="utf-8") as f:
            data = json.load(f)

        if "userSelectedFolders" in data:
            folders = data["userSelectedFolders"]
            log(f"Current folders ({len(folders)}):")
            for i, f in enumerate(folders):
                log(f"  [{i}] {f}")

            if WSL_PATH in folders:
                idx = folders.index(WSL_PATH)
                data["userSelectedFolders"].remove(WSL_PATH)
                log(f"Removed WSL path at index {idx}")

                with open(CURRENT, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=2, ensure_ascii=False)
                log("Session file updated successfully!")
            else:
                log("WSL path NOT FOUND in userSelectedFolders?")
        else:
            log("No userSelectedFolders key found in session file?")
    except PermissionError:
        log("ERROR: Permission denied - file may be locked by running app")
    except Exception as e:
        log(f"ERROR: {e}")
else:
    log(f"ERROR: File not found: {CURRENT}")

# 2. Also find and fix ALL session files with WSL path
log("\n--- Step 2: Scan all session files ---")
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith(".json"):
            fp = os.path.join(root, f)
            try:
                with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                    content = fh.read(100000)
                if WSL_PATH in content and f != os.path.basename(CURRENT):
                    log(f"Found WSL in: {os.path.relpath(fp, CLAUDE_DATA)}")
                    # Try to fix this file too
                    try:
                        with open(fp, "r", encoding="utf-8") as fh:
                            d = json.load(fh)
                        if "userSelectedFolders" in d and WSL_PATH in d["userSelectedFolders"]:
                            d["userSelectedFolders"].remove(WSL_PATH)
                            # Backup
                            shutil.copy2(fp, fp + ".backup")
                            with open(fp, "w", encoding="utf-8") as fh:
                                json.dump(d, fh, indent=2, ensure_ascii=False)
                            log(f"  -> Fixed!")
                    except:
                        log(f"  -> Could not modify (locked or error)")
            except:
                pass

# 3. Search for ANY global config that also stores userSelectedFolders
log("\n--- Step 3: Search for global userSelectedFolders config ---")
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith(".json") and f != os.path.basename(CURRENT):
            fp = os.path.join(root, f)
            try:
                if os.path.getsize(fp) > 500000:
                    continue
                with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                    content = fh.read(500000)
                if "userSelectedFolders" in content:
                    log(f"GLOBAL CONFIG FOUND: {os.path.relpath(fp, CLAUDE_DATA)}")
                    try:
                        d = json.loads(content)
                        if "userSelectedFolders" in d:
                            log(f"  Folders: {d['userSelectedFolders']}")
                    except:
                        log(f"  (not valid JSON)")
            except:
                pass

log("\n=== Done ===")
log_path = LOG
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"\nResult saved to: {LOG}")
