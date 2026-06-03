import os, json

USER = r"C:\Users\wsx"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
CLAUDE_DATA = PKG + r"\LocalCache\Local\Claude-3p"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\global_config_result.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Read global config files ===")

files_to_read = [
    "claude_desktop_config.json",
    "developer_settings.json",
    "window-state.json",
    "cowork_account_settings.json",
]

# Also find cowork_account_settings.json in session dir
session_base = CLAUDE_DATA + r"\local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001"
files_to_read.append(os.path.join(session_base, "cowork_account_settings.json"))

for fname in files_to_read:
    if not os.path.isabs(fname):
        fp = os.path.join(CLAUDE_DATA, fname)
    else:
        fp = fname

    log(f"\n--- {os.path.relpath(fp, CLAUDE_DATA)} ---")
    if os.path.exists(fp):
        log(f"Size: {os.path.getsize(fp)} bytes")
        try:
            with open(fp, "r", encoding="utf-8") as f:
                content = f.read()
            data = json.loads(content)
            log(f"Content: {json.dumps(data, indent=2, ensure_ascii=False)[:2000]}")
        except Exception as e:
            log(f"Error: {e}")
    else:
        log("NOT FOUND")

# Also check Partitions\cowork-file-preview\Preferences
pref2 = CLAUDE_DATA + r"\Partitions\cowork-file-preview\Preferences"
log(f"\n--- Partitions\\cowork-file-preview\\Preferences ---")
if os.path.exists(pref2):
    try:
        with open(pref2, "r", encoding="utf-8") as f:
            log(f"Content: {f.read()[:500]}")
    except:
        log("Cannot read")

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"\nResult: {LOG}")
