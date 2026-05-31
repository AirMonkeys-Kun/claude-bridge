import os, json, glob

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
SESSIONS_DIR = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")
WSL_PATH = r"\\wsl.localhost\ubuntu\home\yck"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\check_session_result.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Check if WSL path reappeared after restart ===")

# Find most recently modified session file
latest_fp = None
latest_mtime = 0
for root, dirs, files in os.walk(SESSIONS_DIR):
    for f in files:
        if f.endswith(".json") and f.startswith("local_") and not f.endswith(".backup"):
            fp = os.path.join(root, f)
            mtime = os.path.getmtime(fp)
            if mtime > latest_mtime:
                latest_mtime = mtime
                latest_fp = fp

if latest_fp:
    import datetime
    mtime_dt = datetime.datetime.fromtimestamp(latest_mtime)
    log(f"Latest session file: {os.path.basename(latest_fp)}")
    log(f"Modified: {mtime_dt}")

    with open(latest_fp, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    if "userSelectedFolders" in data:
        folders = data["userSelectedFolders"]
        log(f"userSelectedFolders ({len(folders)} items):")
        for i, folder in enumerate(folders):
            marker = " <<< WSL!!!" if WSL_PATH in folder else ""
            log(f"  [{i}] {folder}{marker}")

        if WSL_PATH in folders:
            log("\n>>> WSL PATH REAPPEARED after restart!")
        else:
            log("\n>>> SUCCESS: WSL path did NOT reappear!")
    else:
        log("No userSelectedFolders found in latest session")
else:
    log("No session files found!")

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
