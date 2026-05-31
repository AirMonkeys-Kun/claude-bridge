import os, json, shutil

CLAUDE_DATA = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
SESSIONS_DIR = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")
sid = "3745f28d-e68c-44c8-84bd-0d0401d33981"
sub = "00000000-0000-4000-8000-000000000001"
fp = os.path.join(SESSIONS_DIR, sid, sub, "scheduled-tasks.json")
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\fix_scheduled_result.txt"
WSL = r"\\wsl.localhost\ubuntu\home\yck"
results = []

def log(m): print(m); results.append(str(m))

log("=== Fix scheduled-tasks.json ===")

if not os.path.exists(fp):
    log(f"File not found: {fp}")
else:
    with open(fp, "r", encoding="utf-8") as f:
        data = json.load(f)

    tasks = data.get("scheduledTasks", [])
    log(f"Found {len(tasks)} scheduled tasks")

    changed = 0
    for task in tasks:
        folders = task.get("userSelectedFolders", [])
        if WSL in folders:
            folders.remove(WSL)
            task["userSelectedFolders"] = folders
            log(f"  Removed WSL from task: {task['id']}")
            changed += 1

    if changed > 0:
        backup = fp + ".backup2"
        shutil.copy2(fp, backup)
        log(f"Backup: {backup}")

        with open(fp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        log(f"Saved: {changed} task(s) fixed")
    else:
        log("No changes needed")

    # Verify
    with open(fp, "r", encoding="utf-8") as f:
        data2 = json.load(f)

    wsl_found = False
    for task in data2.get("scheduledTasks", []):
        for folder in task.get("userSelectedFolders", []):
            if WSL in folder:
                log(f"  WARNING: Still in task {task['id']}: {folder}")
                wsl_found = True

    if not wsl_found:
        log("VERIFIED: No WSL path remains in scheduled-tasks.json")

# Final: scan ALL user-accessible files for WSL
log("\n--- Full verification scan ---")
wsl_count = 0
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp2 = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp2)
            if sz > 5000000:
                continue
            with open(fp2, "rb") as fh:
                d = fh.read(min(sz, 200000))
            if WSL.encode() in d:
                rel = os.path.relpath(fp2, CLAUDE_DATA)
                log(f"  WSL remains in: {rel}")
                wsl_count += 1
        except:
            pass

if wsl_count == 0:
    log("\n>>> ALL CLEAR: WSL path removed from all config files!")
else:
    log(f"\n>>> {wsl_count} file(s) still contain WSL path (probably memory/doc files)")

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
