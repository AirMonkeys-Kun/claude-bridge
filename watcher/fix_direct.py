import json, os, shutil

# Direct paths
SESSION_BASE = r"C:\Users\Administrator\AppData\Local\Claude-3p\local-agent-mode-sessions"
CURRENT_SESSION = os.path.join(
    SESSION_BASE,
    "03aba519-9779-4a1a-bed2-07f2a074a5f9",
    "00000000-0000-4000-8000-000000000001",
    "local_2ec39a9d-2deb-4b36-ac7d-36b914d6da00.json"
)

WSL_DOMAIN = r"\\wsl.localhost"

fixed_count = 0

def fix_json_file(fp):
    global fixed_count
    try:
        with open(fp, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            return
        if "userSelectedFolders" not in data:
            return
        original = list(data["userSelectedFolders"])
        data["userSelectedFolders"] = [p for p in original if not p.startswith(WSL_DOMAIN)]
        if len(data["userSelectedFolders"]) != len(original):
            shutil.copy2(fp, fp + ".backup4")
            with open(fp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            removed = [p for p in original if p.startswith(WSL_DOMAIN)]
            print(f"  FIXED {os.path.basename(fp)}: removed {len(removed)} WSL paths")
            fixed_count += 1
    except Exception as e:
        print(f"  ERROR {os.path.basename(fp)}: {e}")

# Fix current session
print("=== Fixing current session JSON ===")
fix_json_file(CURRENT_SESSION)

# Fix all session JSONs in all project dirs
print("\n=== Scanning all session JSONs ===")
for root, dirs, files in os.walk(SESSION_BASE):
    for f in files:
        if f.endswith(".backup") or f.endswith(".backup2") or f.endswith(".backup3") or f.endswith(".backup4"):
            continue
        if not f.endswith(".json"):
            continue
        fp = os.path.join(root, f)
        if fp == CURRENT_SESSION:
            continue  # already fixed
        fix_json_file(fp)

# Fix scheduled-tasks.json
print("\n=== Fixing scheduled-tasks.json ===")
st_path = os.path.join(SESSION_BASE, "scheduled-tasks.json")
if os.path.exists(st_path):
    fix_json_file(st_path)
else:
    print("  Not found")

print(f"\n=== Total fixed: {fixed_count} ===")
