import os, json, glob

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
SESSIONS_DIR = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\sandbox_config_search.txt"
PROCESS_NAME = "ecstatic-beautiful-hopper"
WSL_PATH = r"\\wsl.localhost\ubuntu\home\yck"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Search for sandbox config source ===")
log(f"Process name: {PROCESS_NAME}")

# 1. Search for processName in ALL files
log(f"\n--- 1. Search for '{PROCESS_NAME}' in all files ---")
found_count = 0
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            if sz > 2000000:  # skip > 2MB
                continue
            with open(fp, "rb") as fh:
                data = fh.read(min(sz, 100000))
            if PROCESS_NAME.encode("utf-8") in data:
                rel = os.path.relpath(fp, CLAUDE_DATA)
                log(f"  Found in: {rel} ({sz:,} bytes)")
                # Show some context
                idx = data.index(PROCESS_NAME.encode("utf-8"))
                ctx = data[max(0, idx - 50):idx + 150]
                printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
                log(f"    Context: ...{printable}...")
                found_count += 1
        except:
            pass

log(f"\n  Total files with processName: {found_count}")

# 2. Search for parent directory that might have sandbox config
log(f"\n--- 2. Files in process-specific directories ---")
session_id = "3745f28d-e68c-44c8-84bd-0d0401d33981"
sub_id = "00000000-0000-4000-8000-000000000001"
session_path = os.path.join(SESSIONS_DIR, session_id, sub_id)
if os.path.isdir(session_path):
    for root, dirs, files in os.walk(session_path):
        for f in files:
            if f.endswith(".json"):
                fp = os.path.join(root, f)
                rel = os.path.relpath(fp, SESSIONS_DIR)
                sz = os.path.getsize(fp)
                mtime = os.path.getmtime(fp)
                import datetime
                dt = datetime.datetime.fromtimestamp(mtime)
                log(f"  {rel} ({sz:,} bytes, {dt})")

# 3. Check if there's a folder selection stored somewhere else
log(f"\n--- 3. Search for 'folders' array with WSL-like content ---")
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if not f.endswith(".json"):
            continue
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            with open(fp, "r", encoding="utf-8") as fh:
                content = fh.read()
            if "wsl.localhost" in content.lower() and "folders" in content.lower():
                rel = os.path.relpath(fp, CLAUDE_DATA)
                log(f"  FOUND: {rel} ({sz:,} bytes)")
                # Show relevant lines
                for line in content.split('\n'):
                    if "wsl" in line.lower():
                        log(f"    -> {line.strip()[:120]}")
        except:
            pass

log(f"\n=== Done ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
