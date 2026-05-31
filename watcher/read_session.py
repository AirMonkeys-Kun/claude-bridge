import os, json

USER = r"C:\Users\wsx"
BASE = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001"

# Read current session file
current = os.path.join(BASE, "local_8108405e-cac5-481d-9ad7-a58b2452fc01.json")
with open(current, "r", encoding="utf-8") as f:
    data = json.load(f)

print("=== Current session JSON structure ===")
print(f"Top-level keys: {list(data.keys())}")
print(f"Type: {type(data)}")

# Show all fields
for k, v in data.items():
    if isinstance(v, str) and len(v) > 500:
        print(f"\n  {k}: (string, {len(v)} chars)")
        print(f"    Preview: {v[:200]}...")
    elif isinstance(v, dict):
        print(f"\n  {k}: (dict, {len(v)} keys)")
        print(f"    Keys: {list(v.keys())[:20]}")
        # Show first 300 chars
        preview = json.dumps(v, ensure_ascii=False)[:300]
        print(f"    Preview: {preview}")
    elif isinstance(v, list):
        print(f"\n  {k}: (list, {len(v)} items)")
        for i, item in enumerate(v[:5]):
            print(f"    [{i}]: {json.dumps(item, ensure_ascii=False)[:200]}")
    else:
        print(f"\n  {k}: {json.dumps(v, ensure_ascii=False)[:300]}")

# Search for "wsl" and "folder" references
print("\n\n=== Looking for 's' array (workspace folders) ===")
if isinstance(data, dict):
    for k, v in data.items():
        if isinstance(v, list):
            for i, item in enumerate(v):
                if isinstance(item, str) and ("wsl" in item.lower() or "folder" in item.lower() or "workspace" in item.lower()):
                    print(f"  Found in {k}[{i}]: {item}")
                elif isinstance(item, dict):
                    for ik, iv in item.items():
                        if isinstance(iv, str) and ("wsl" in iv.lower() or "folder" in iv.lower()):
                            print(f"  Found in {k}[{i}].{ik}: {iv}")

# Also check if "s" key exists
if isinstance(data, dict) and "s" in data:
    print(f"\n  's' key found! Type: {type(data['s'])}")
    print(f"  Value: {json.dumps(data['s'], ensure_ascii=False)[:500]}")

# Save a clean output
OUT = r"C:\Users\wsx\Desktop\claude-bridge\watcher\session_structure.txt"
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print(f"\nFull JSON saved to: {OUT} ({os.path.getsize(OUT)} bytes)")
