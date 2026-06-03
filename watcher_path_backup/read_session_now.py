import json, os, datetime

fp = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\local-agent-mode-sessions\3745f28d-e68c-44c8-84bd-0d0401d33981\00000000-0000-4000-8000-000000000001\local_8108405e-cac5-481d-9ad7-a58b2452fc01.json"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\session_now.txt"
WSL = r"\\wsl.localhost\ubuntu\home\yck"

ts = os.path.getmtime(fp)
dt = datetime.datetime.fromtimestamp(ts)
print(f"MTime: {dt}")
print(f"Now: {datetime.datetime.now()}")

with open(fp, "r", encoding="utf-8") as f:
    d = json.load(f)

folders = d.get("userSelectedFolders", [])
print(f"Folders: {len(folders)} items")
for i, f in enumerate(folders):
    marker = " <<< WSL" if WSL in f else ""
    print(f"  [{i}] {f}{marker}")

has_wsl = WSL in folders
print(f"\nWSL present: {has_wsl}")

with open(LOG, "w", encoding="utf-8") as f:
    f.write(f"MTime: {dt}\n")
    f.write(f"Folders: {len(folders)} items\n")
    for i, folder in enumerate(folders):
        marker = " <<< WSL" if WSL in folder else ""
        f.write(f"  [{i}] {folder}{marker}\n")
    f.write(f"\nWSL present: {has_wsl}\n")
