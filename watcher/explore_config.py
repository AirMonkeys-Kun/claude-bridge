"""探索 Claude Desktop 配置文件结构"""
import os, json, sys
from pathlib import Path

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\config_explore.txt"

def log(msg):
    print(msg)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(msg + "\n")

log("="*60)
log("Claude Desktop 配置探索")
log("="*60)

# 1. 可能的数据目录
local = os.environ.get("LOCALAPPDATA", "")
roaming = os.environ.get("APPDATA", "")
user = os.environ.get("USERPROFILE", "")

paths = [
    os.path.join(local, "Claude-3p"),
    os.path.join(roaming, "Claude-3p"),
    os.path.join(user, "AppData", "Local", "Claude-3p"),
    os.path.join(user, "AppData", "Roaming", "Claude-3p"),
]

log(f"User: {user}")
log(f"LocalAppData: {local}")
log(f"AppData: {roaming}")
log("")

for base in paths:
    if os.path.isdir(base):
        log(f"=== EXISTS: {base} ===")
        # List all files recursively
        for root, dirs, files in os.walk(base):
            depth = root.replace(base, "").count(os.sep)
            if depth > 4:  # limit depth
                continue
            rel = os.path.relpath(root, base)

            # Check for interesting files
            for f in files:
                fpath = os.path.join(root, f)
                fsize = os.path.getsize(fpath)

                # Look for config-like files
                interesting = False
                for kw in ["config", "setting", "preference", "workspace", "folder", "mount",
                          "session", "state", "storage", "leveldb", "ldb", "log", "json", "sqlite"]:
                    if kw in f.lower():
                        interesting = True
                        break

                if interesting or fsize > 100000:  # Large files
                    log(f"  [{rel}] {f} ({fsize:,} bytes)")

        # Also show top-level directories
        log("\nTop-level items:")
        for item in os.listdir(base):
            item_path = os.path.join(base, item)
            if os.path.isdir(item_path):
                try:
                    items = len(os.listdir(item_path))
                except:
                    items = -1
                log(f"  📁 {item}/ ({items} items)")
            else:
                size = os.path.getsize(item_path)
                log(f"  📄 {item} ({size:,} bytes)")
        log("")

# 2. Look for workspace related files specifically
log("=== Searching for workspace/folder config ===")
for base in paths:
    if not os.path.isdir(base):
        continue
    for root, dirs, files in os.walk(base):
        for f in files:
            fpath = os.path.join(root, f)
            try:
                # Check small text files for workspace keywords
                if os.path.getsize(fpath) < 500000:  # < 500KB
                    if f.endswith((".json", ".txt", ".log", ".cfg", ".conf", ".ini")):
                        with open(fpath, "r", encoding="utf-8", errors="ignore") as fp:
                            content = fp.read()
                            for kw in ["wsl", "folder", "workspace", "mount", "selectedFolder",
                                      "wsl.localhost", "\\wsl", "ubuntu", "mounted"]:
                                if kw in content.lower():
                                    rel = os.path.relpath(fpath, base)
                                    # Get context around the match
                                    idx = content.lower().find(kw)
                                    start = max(0, idx - 60)
                                    end = min(len(content), idx + 60)
                                    context = content[start:end].replace('\n', '\\n')
                                    log(f"MATCH in {rel}")
                                    log(f"  context: ...{context}...")
                                    log("")
                                    break
            except:
                pass

log("=== DONE ===")
print(f"\nResults saved to: {LOG}")
