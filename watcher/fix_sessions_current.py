import os, json, glob, shutil

USER = "Administrator"
CLAUDE_DATA = f"C:\\Users\\{USER}\\AppData\\Local\\Claude-3p"
SESSIONS_DIR = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")

# Multiple WSL path variants to remove
WSL_PATHS = [
    r"\\wsl.localhost\ubuntu\home\administrator\projects\chatbot\src",
    r"\\wsl.localhost\ubuntu\home\administrator\projects\chatbot\tests",
    r"\\wsl.localhost\ubuntu\home\administrator\projects\chatbot",
    r"\\wsl.localhost\ubuntu\home\administrator\projects",
]
WSL_DOMAIN = r"\\wsl.localhost"
log_lines = []

def log(msg):
    print(msg)
    log_lines.append(msg)

log("=== Fix: Remove ALL WSL UNC paths from userSelectedFolders ===")

# 1. Fix current session JSON (the one with our session ID)
session_id = None
for root, dirs, files in os.walk(SESSIONS_DIR):
    for f in files:
        if f.startswith("local_") and f.endswith(".json") and not f.endswith(".backup") and not f.endswith(".backup2"):
            fp = os.path.join(root, f)
            try:
                with open(fp, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
                if isinstance(data, dict) and "userSelectedFolders" in data:
                    folders = data["userSelectedFolders"]
                    changed = False
                    new_folders = [p for p in folders if not p.startswith(WSL_DOMAIN)]
                    if len(new_folders) != len(folders):
                        removed = [p for p in folders if p.startswith(WSL_DOMAIN)]
                        data["userSelectedFolders"] = new_folders
                        shutil.copy2(fp, fp + ".backup2")
                        with open(fp, "w", encoding="utf-8") as fw:
                            json.dump(data, fw, ensure_ascii=False, indent=2)
                        log(f"  FIXED: {f} — removed {len(removed)} WSL paths: {removed}")
                        changed = True
                    if not changed:
                        log(f"  OK: {f} — no WSL paths")
            except Exception as e:
                log(f"  SKIP {f}: {e}")

# 2. Fix scheduled-tasks.json
scheduled_tasks = os.path.join(SESSIONS_DIR, "scheduled-tasks.json")
if os.path.exists(scheduled_tasks):
    try:
        with open(scheduled_tasks, "r", encoding="utf-8") as fh:
            st_data = json.load(fh)
        changed = False
        if "scheduledTasks" in st_data:
            for task in st_data["scheduledTasks"]:
                if "userSelectedFolders" in task:
                    old_count = len(task["userSelectedFolders"])
                    task["userSelectedFolders"] = [p for p in task["userSelectedFolders"] if not p.startswith(WSL_DOMAIN)]
                    if len(task["userSelectedFolders"]) != old_count:
                        log(f"  FIXED scheduled task '{task.get('id','?')}': removed WSL paths")
                        changed = True
        if changed:
            shutil.copy2(scheduled_tasks, scheduled_tasks + ".backup2")
            with open(scheduled_tasks, "w", encoding="utf-8") as fw:
                json.dump(st_data, fw, ensure_ascii=False, indent=2)
            log("  scheduled-tasks.json saved")
        else:
            log("  scheduled-tasks.json: no WSL paths found")
    except Exception as e:
        log(f"  ERROR scheduled-tasks.json: {e}")
else:
    log("  scheduled-tasks.json not found")

# 3. Fix all other session JSONs
log("\n--- Scanning all session JSONs ---")
found = 0
fixed = 0
for root, dirs, files in os.walk(SESSIONS_DIR):
    for f in files:
        if f.endswith(".backup") or f.endswith(".backup2"):
            continue
        if not f.endswith(".json"):
            continue
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            if sz > 5000000:
                continue
            with open(fp, "r", encoding="utf-8") as fh:
                content = fh.read()
            if WSL_DOMAIN not in content:
                continue
            found += 1
            obj = json.loads(content)

            # Handle dict and list
            items = []
            if isinstance(obj, dict):
                items = [(obj, "")]
            elif isinstance(obj, list):
                items = [(item, f"[{i}]") for i, item in enumerate(obj)]

            changed = False
            for target, prefix in items:
                if "userSelectedFolders" in target:
                    old = target["userSelectedFolders"]
                    target["userSelectedFolders"] = [p for p in old if not p.startswith(WSL_DOMAIN)]
                    if len(target["userSelectedFolders"]) != len(old):
                        log(f"  FIXED: {f}{prefix}")
                        changed = True

            if changed:
                shutil.copy2(fp, fp + ".backup2")
                with open(fp, "w", encoding="utf-8") as fw:
                    json.dump(obj, fw, ensure_ascii=False, indent=2)
                fixed += 1
        except Exception as e:
            log(f"  ERROR {f}: {e}")

log(f"\n=== Summary ===")
log(f"  Files with WSL: {found}")
log(f"  Files fixed: {fixed}")

# 4. Verify
log("\n--- Verification ---")
remaining = 0
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            if sz > 5000000 or f.endswith(".backup") or f.endswith(".backup2"):
                continue
            with open(fp, "rb") as fh:
                data = fh.read(min(sz, 500000))
            if WSL_DOMAIN.encode("utf-8") in data:
                rel = os.path.relpath(fp, CLAUDE_DATA)
                log(f"  STILL HAS WSL: {rel}")
                remaining += 1
        except:
            pass

if remaining == 0:
    log("\n>>> ALL CLEAN: No WSL UNC paths remaining!")
else:
    log(f"\n>>> WARNING: {remaining} file(s) still contain WSL paths")

LOG = r"D:\zebbingo\claude-bridge\watcher\fix_result.txt"
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(log_lines))
print(f"\nResult: {LOG}")
