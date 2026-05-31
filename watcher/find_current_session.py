import os, json, time

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
SESSIONS_DIR = CLAUDE_DATA + r"\local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\new_session_result.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Find current session file after restart ===")
log(f"Time: {time.strftime('%H:%M:%S')}")

# List all JSON files in the session directory
if os.path.isdir(SESSIONS_DIR):
    for f in sorted(os.listdir(SESSIONS_DIR)):
        fp = os.path.join(SESSIONS_DIR, f)
        if os.path.isfile(fp) and f.endswith(".json"):
            mtime = os.path.getmtime(fp)
            mtime_str = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(mtime))
            size = os.path.getsize(fp)
            log(f"  {f} ({size:,} bytes, modified: {mtime_str})")

            # Read and check for userSelectedFolders
            try:
                with open(fp, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
                if "userSelectedFolders" in data:
                    log(f"    userSelectedFolders ({len(data['userSelectedFolders'])} items):")
                    for i, folder in enumerate(data["userSelectedFolders"]):
                        marker = " <<< WSL" if "wsl" in folder.lower() else ""
                        log(f"      [{i}] {folder}{marker}")
                if "processName" in data:
                    log(f"    processName: {data['processName']}")
            except Exception as e:
                log(f"    (error reading: {e})")

log("\n=== Done ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"\nResult: {LOG}")
