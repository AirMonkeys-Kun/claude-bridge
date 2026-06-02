import os, json

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\scan_read_result.json"
USER = r"C:\Users\wsx"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
CLAUDE_DATA = PKG + r"\LocalCache\Local\Claude-3p"

results = {}

# 1. Read config.json
config_path = os.path.join(CLAUDE_DATA, "config.json")
results["config.json"] = {"exists": os.path.isfile(config_path)}
if results["config.json"]["exists"]:
    with open(config_path, "r", encoding="utf-8", errors="ignore") as f:
        results["config.json"]["content"] = f.read()

# 2. Read Local State
ls_path = os.path.join(CLAUDE_DATA, "Local State")
results["Local State"] = {"exists": os.path.isfile(ls_path)}
if results["Local State"]["exists"]:
    with open(ls_path, "r", encoding="utf-8", errors="ignore") as f:
        results["Local State"]["content"] = f.read()

# 3. Read Preferences
pref_path = os.path.join(CLAUDE_DATA, "Preferences")
results["Preferences"] = {"exists": os.path.isfile(pref_path)}
if results["Preferences"]["exists"]:
    with open(pref_path, "r", encoding="utf-8", errors="ignore") as f:
        results["Preferences"]["content"] = f.read()

# 4. Find all session JSON files that contain the WSL path
session_dir = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")
wsl_files = []
if os.path.isdir(session_dir):
    for root, dirs, files in os.walk(session_dir):
        for f in files:
            if f.endswith(".json"):
                fp = os.path.join(root, f)
                try:
                    with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                        content = fh.read()
                    if "wsl.localhost" in content:
                        wsl_files.append({"file": fp.replace(CLAUDE_DATA, ""), "size": os.path.getsize(fp)})
                        # Check if this has an "s" array with the workspaces
                        if '"s"' in content or '"s":' in content:
                            wsl_files[-1]["has_s_array"] = True
                except:
                    pass

results["session_files_with_wsl"] = wsl_files
results["session_file_count"] = len(wsl_files)

# 5. Search for workspace folder config in all JSON files
workspace_configs = []
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith(".json"):
            fp = os.path.join(root, f)
            try:
                if os.path.getsize(fp) > 200000:
                    continue
                with open(fp, "r", encoding="utf-8", errors="ignore") as fh:
                    content = fh.read()
                # Look for "s" array pattern with folder paths
                if '"s"' in content and ("folder" in content.lower() or "workspace" in content.lower() or "wsl" in content.lower()):
                    rel = fp.replace(CLAUDE_DATA, "")
                    size = os.path.getsize(fp)
                    workspace_configs.append({"file": rel, "size": size,
                                              "preview": content[:2000]})
            except:
                pass

results["other_workspace_configs"] = workspace_configs

# 6. Check for any file named "project", "workspace" or "folder"
named_files = []
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if any(kw in f.lower() for kw in ["project", "workspace", "folder", "mount", "session"]):
            fp = os.path.join(root, f)
            named_files.append({"file": fp.replace(CLAUDE_DATA, ""), "size": os.path.getsize(fp)})

results["named_config_files"] = named_files

with open(LOG, "w", encoding="utf-8") as f:
    json.dump(results, f, indent=2, ensure_ascii=False)

print(f"=== Scan Results ===")
print(f"config.json: {'EXISTS' if results['config.json']['exists'] else 'NOT FOUND'}")
print(f"Local State: {'EXISTS' if results['Local State']['exists'] else 'NOT FOUND'}")
print(f"Preferences: {'EXISTS' if results['Preferences']['exists'] else 'NOT FOUND'}")
print(f"Session files with WSL path: {len(wsl_files)}")
for wf in wsl_files:
    print(f"  {wf['file']} ({wf['size']} bytes) s_array={wf.get('has_s_array',False)}")
print(f"Other workspace configs: {len(workspace_configs)}")
print(f"Named config files: {len(named_files)}")

# Print config.json content preview
if results["config.json"]["exists"]:
    c = results["config.json"]["content"]
    print(f"\n--- config.json (first 2000 chars) ---")
    print(c[:2000])

# Print Local State content
if results["Local State"]["exists"]:
    c = results["Local State"]["content"]
    print(f"\n--- Local State (full) ---")
    print(c[:3000])

# Print Preferences content
if results["Preferences"]["exists"]:
    c = results["Preferences"]["content"]
    print(f"\n--- Preferences (first 2000 chars) ---")
    print(c[:2000])

print(f"\nFull results: {LOG}")
