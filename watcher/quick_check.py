import os, json

USER = r"C:\Users\wsx"
CLAUDE_DATA = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\quick_check.txt"
results = []

def log(m): print(m); results.append(str(m))

sid = "3745f28d-e68c-44c8-84bd-0d0401d33981"
sub = "00000000-0000-4000-8000-000000000001"
session_dir = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions", sid, sub)

log("=== Quick check ===")
log(f"Session dir exists: {os.path.isdir(session_dir)}")

# List JSON files
json_files = []
for root, dirs, files in os.walk(session_dir):
    for f in files:
        if f.endswith(".json"):
            fp = os.path.join(root, f)
            try:
                sz = os.path.getsize(fp)
                json_files.append((f, sz, root))
            except:
                json_files.append((f, "ERR", root))

log(f"JSON files: {len(json_files)}")
for fname, sz, root in json_files:
    rel = os.path.relpath(os.path.join(root, fname), session_dir)
    log(f"  {rel} [{sz}]")

# Check the most important files: the top-level JSON and cowork_account_settings
for fname in ["cowork_account_settings.json", "spaces.json", "scheduled-tasks.json"]:
    fp = os.path.join(session_dir, fname)
    if os.path.exists(fp):
        with open(fp, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        s = json.dumps(data, ensure_ascii=False, indent=2)
        log(f"\n--- {fname} ---")
        # Only show first 2000 chars
        if len(s) > 2000:
            log(s[:2000] + "\n... (truncated)")
        else:
            log(s)

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
