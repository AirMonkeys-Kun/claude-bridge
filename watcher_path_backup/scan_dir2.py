import os, json

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\scan_result2.json"
USER = r"C:\Users\wsx"

results = {"explored_dirs": [], "all_files": [], "workspace_matches": [], "file_structure": {}}

targets = [
    USER + r"\AppData\Local\Claude-3p",
    USER + r"\AppData\Roaming\Claude-3p",
    USER + r"\AppData\Local\Cowork",
    USER + r"\AppData\Roaming\Cowork",
    USER + r"\.claude",
]

for base in targets:
    if not os.path.isdir(base):
        continue
    results["explored_dirs"].append(base)
    structure = {}
    for root, dirs, files in os.walk(base):
        depth = root.replace(base, "").count(os.sep)
        if depth > 6:
            dirs.clear()
            continue
        rel = os.path.relpath(root, base) if root != base else "."
        if rel == ".":
            # top-level dirs
            for d in sorted(dirs):
                dp = os.path.join(root, d)
                count = len(os.listdir(dp))
                results["all_files"].append({"path": d + "/", "size": 0, "type": "dir", "items": count})
            for f in sorted(files):
                fp = os.path.join(root, f)
                sz = os.path.getsize(fp)
                results["all_files"].append({"path": f, "size": sz, "type": "file"})
        else:
            # deeper files
            for f in sorted(files):
                fp = os.path.join(root, f)
                try:
                    sz = os.path.getsize(fp)
                    results["all_files"].append({"path": rel + "/" + f, "size": sz, "type": "file"})
                except:
                    pass

# Search ALL text files for workspace keywords
keywords = ["wsl", "workspace", "folder", "mount", "selected",
            "wsl.localhost", "mounted", "add-dir", "projectRoot"]

for base in targets:
    if not os.path.isdir(base):
        continue
    for root, dirs, files in os.walk(base):
        for f in files:
            if f.endswith((".json", ".txt", ".log", ".cfg", ".conf", ".ini", ".yaml", ".yml", ".toml", ".xml", ".js", ".ts")):
                fp = os.path.join(root, f)
                try:
                    if os.path.getsize(fp) > 1000000:
                        continue
                    with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                        content = fh.read(200000)
                    for kw in keywords:
                        if kw.lower() in content.lower():
                            idx = content.lower().index(kw.lower())
                            start = max(0, idx - 60)
                            end = min(len(content), idx + 120)
                            ctx = content[start:end].replace("\n", "\\n").replace("\r", "")
                            results["workspace_matches"].append({
                                "file": fp.replace(USER, "%USER%"),
                                "keyword": kw,
                                "context": ctx[:250]
                            })
                            break
                except:
                    pass

with open(LOG, "w", encoding="utf-8") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)

total_matches = len(results["workspace_matches"])
total_files = len(results["all_files"])
print(f"Scanned {total_files} files in {len(results['explored_dirs'])} dirs")
print(f"Found {total_matches} keyword matches")
print(f"Result: {LOG}")

# Also print any matches
for m in results["workspace_matches"]:
    print(f"\n  MATCH '{m['keyword']}' in {m['file']}")
    print(f"  ...{m['context']}...")
