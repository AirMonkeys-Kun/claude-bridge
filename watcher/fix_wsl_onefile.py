import os, json, shutil

# Target file
target = r"C:\Users\Administrator\AppData\Local\Claude-3p\local-agent-mode-sessions\03aba519-9779-4a1a-bed2-07f2a074a5f9\00000000-0000-4000-8000-000000000001\local_2ec39a9d-2deb-4b36-ac7d-36b914d6da00.json"

# Back it up
shutil.copy2(target, target + ".backup3")

with open(target, "r", encoding="utf-8") as f:
    data = json.load(f)

if "userSelectedFolders" in data:
    original = list(data["userSelectedFolders"])
    wsl_domain = r"\\wsl.localhost"
    data["userSelectedFolders"] = [p for p in data["userSelectedFolders"] if not p.startswith(wsl_domain)]
    removed = [p for p in original if p.startswith(wsl_domain)]
    print(f"Removed {len(removed)} WSL paths: {removed}")
    print(f"Remaining {len(data['userSelectedFolders'])} folders")

with open(target, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

print("Done!")
