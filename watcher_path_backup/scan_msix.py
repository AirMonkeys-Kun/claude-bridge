import os, json

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\scan_msix_result.json"
USER = r"C:\Users\wsx"

results = {"explored_dirs": [], "all_files": [], "workspace_matches": []}

# MSIX packages data is redirected here:
msix_pkg = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
targets = [
    msix_pkg,
    msix_pkg + r"\LocalCache",
    msix_pkg + r"\LocalCache\Roaming",
    msix_pkg + r"\LocalCache\Local",
    msix_pkg + r"\LocalState",
    msix_pkg + r"\LocalCache\Roaming\Claude-3p",
    msix_pkg + r"\LocalCache\Local\Claude-3p",
]

# Also check if there's a redirected LocalAppData
localappdata = os.environ.get("LOCALAPPDATA", USER + r"\AppData\Local")
targets.extend([
    localappdata + r"\Claude-3p\claude-desktop",
    localappdata + r"\claude-desktop",
])

for base in targets:
    if not os.path.isdir(base):
        continue
    results["explored_dirs"].append(base.replace(USER, "%USER%"))
    for root, dirs, files in os.walk(base):
        depth = root.replace(base, "").count(os.sep)
        if depth > 5:
            dirs.clear()
            continue
        rel = os.path.relpath(root, base) if root != base else "."
        for f in sorted(files):
            fp = os.path.join(root, f)
            try:
                sz = os.path.getsize(fp)
                frel = os.path.relpath(fp, base)
                results["all_files"].append({"path": frel, "size": sz})

                # Scan text files for workspace keywords
                if f.endswith((".json", ".txt", ".log", ".db", ".sqlite")):
                    if sz < 500000:
                        with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                            content = fh.read(200000)
                        for kw in ["wsl", "workspace", "folder", "mount", "selected", "mounted", "projectRoot", "add-dir"]:
                            if kw.lower() in content.lower():
                                idx = content.lower().index(kw.lower())
                                ctx = content[max(0,idx-60):idx+120].replace("\n","\\n").replace("\r","")
                                results["workspace_matches"].append({
                                    "file": frel,
                                    "keyword": kw,
                                    "context": ctx[:250]
                                })
                                break
            except:
                pass

with open(LOG, "w", encoding="utf-8") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)

print(f"Explored {len(results['explored_dirs'])} dirs, {len(results['all_files'])} files")
print(f"Found {len(results['workspace_matches'])} keyword matches")
if results["workspace_matches"]:
    for m in results["workspace_matches"]:
        print(f"\n  [{m['keyword']}] {m['file']}")
        print(f"  ...{m['context']}...")
print(f"\nResult: {LOG}")
