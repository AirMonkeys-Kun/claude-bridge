import os, json
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\scan_result.json"

results = {
    "explored_dirs": [],
    "all_files": [],
    "workspace_matches": []
}

def explore(base, max_depth=5):
    if not os.path.isdir(base):
        return
    results["explored_dirs"].append(base)
    for root, dirs, files in os.walk(base):
        depth = root.replace(base, "").count(os.sep)
        if depth > max_depth:
            dirs.clear()
            continue
        for f in files:
            fp = os.path.join(root, f)
            try:
                sz = os.path.getsize(fp)
                rel = os.path.relpath(fp, base)
                results["all_files"].append({"path": rel, "size": sz})
            except:
                pass

# Main targets
targets = [
    os.environ.get("LOCALAPPDATA", "") + "\\Claude-3p",
    os.environ.get("APPDATA", "") + "\\Claude-3p",
    os.environ.get("LOCALAPPDATA", "") + "\\Cowork",
    os.environ.get("APPDATA", "") + "\\Cowork",
    os.environ.get("USERPROFILE", "") + "\\.claude",
]

for t in targets:
    explore(t)

# Search text files for workspace keywords
keywords = ["wsl.localhost", "selectedFolder", "mountedFolder", "workspaceFolder",
            "userSelected", "\\wsl", "wsl", "workspace", "mounted", "add-dir", "projectRoot"]
for t in targets:
    if not os.path.isdir(t):
        continue
    for root, dirs, files in os.walk(t):
        for f in files:
            if f.endswith((".json", ".txt", ".log", ".cfg", ".conf", ".ini", ".yaml", ".yml", ".toml", ".xml")):
                fp = os.path.join(root, f)
                try:
                    if os.path.getsize(fp) > 500000:
                        continue
                    with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                        content = fh.read()
                    for kw in keywords:
                        if kw in content:
                            idx = content.index(kw)
                            ctx = content[max(0,idx-50):idx+100]
                            results["workspace_matches"].append({
                                "file": fp,
                                "keyword": kw,
                                "context": ctx[:200]
                            })
                            break
                except:
                    pass

with open(LOG, "w", encoding="utf-8") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)
print(f"Done! Found {len(results['all_files'])} files, {len(results['workspace_matches'])} keyword matches")
print(f"Results: {LOG}")
