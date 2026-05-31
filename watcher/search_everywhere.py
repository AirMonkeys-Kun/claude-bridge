import os, json

USER = r"C:\Users\wsx"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
CLAUDE_DATA = PKG + r"\LocalCache\Local\Claude-3p"
TEMP = r"C:\Users\wsx\Desktop\claude-bridge\watcher"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\final_search.txt"
results = []

def log(msg): print(msg); results.append(msg)

log("=== Exhaustive search for workspace folder config ===")
log("Target: find where userSelectedFolders is PERSISTED")

# Search patterns
patterns = [b"\\\\wsl", b"wsl.localhost", b"\\\\wsl$", b"userSelectedFolders",
            b"ubuntu", b"SelectedFolders", b"selectedFolder"]

# 1. Check MSIX Settings directory
log("\n--- 1. MSIX Package Settings ---")
settings_dir = PKG + r"\Settings"
if os.path.isdir(settings_dir):
    for root, dirs, files in os.walk(settings_dir):
        for f in files:
            fp = os.path.join(root, f)
            rel = os.path.relpath(fp, PKG)
            sz = os.path.getsize(fp)
            try:
                with open(fp, "rb") as fh:
                    data = fh.read(500000)
                found_patterns = []
                for pat in patterns:
                    if pat.lower() in data.lower():
                        found_patterns.append(pat.decode())
                if found_patterns:
                    log(f"  FOUND in {rel} ({sz:,} bytes): {found_patterns}")
                elif sz < 100000:
                    log(f"  {rel} ({sz:,} bytes) - no match")
            except:
                log(f"  {rel} ({sz:,} bytes) - cannot read")
else:
    log(f"  Settings dir NOT FOUND at {settings_dir}")

# 2. Check SystemAppData
log("\n--- 2. SystemAppData ---")
sysdata = PKG + r"\SystemAppData"
if os.path.isdir(sysdata):
    for root, dirs, files in os.walk(sysdata):
        for f in files:
            fp = os.path.join(root, f)
            try:
                sz = os.path.getsize(fp)
                if sz > 0:
                    with open(fp, "rb") as fh:
                        data = fh.read(500000)
                    for pat in patterns:
                        if pat.lower() in data.lower():
                            rel = os.path.relpath(fp, PKG)
                            log(f"  FOUND in {rel}")
                            break
            except:
                pass
else:
    log(f"  SystemAppData NOT FOUND")

# 3. Search LevelDB files with broader patterns
log("\n--- 3. LevelDB comprehensive scan ---")
leveldb_files = []
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith((".ldb", ".log")) and "leveldb" in root.lower():
            fp = os.path.join(root, f)
            leveldb_files.append((f, os.path.getsize(fp), os.path.dirname(fp)))

for fname, fsize, fdir in leveldb_files:
    fp = os.path.join(fdir, fname)
    try:
        with open(fp, "rb") as fh:
            data = fh.read(500000)
        found = False
        for pat in patterns:
            if pat.lower() in data.lower():
                if not found:
                    rel = os.path.relpath(fp, CLAUDE_DATA)
                    log(f"  FOUND in {rel}")
                    found = True
                # Find position
                idx = data.lower().index(pat.lower())
                ctx = data[max(0, idx - 30):idx + 100]
                # Make printable
                printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
                log(f"    at offset {idx}: ...{printable}...")
    except:
        pass

# 4. Search for ANY file with "selectedFolder" or "userSelected"
log("\n--- 4. Search for 'userSelected' in ALL accessible files ---")
for root, dirs, files in os.walk(PKG):
    for f in files:
        fp = os.path.join(root, f)
        try:
            sz = os.path.getsize(fp)
            if sz > 10000000:  # skip > 10MB
                continue
            with open(fp, "rb") as fh:
                data = fh.read(sz if sz < 500000 else 500000)
            for pat in [b"userSelectedFolder", b"SelectedFolders"]:
                if pat in data:
                    rel = os.path.relpath(fp, PKG)
                    log(f"  '{pat.decode()}' FOUND in {rel}")
                    idx = data.index(pat)
                    ctx = data[max(0, idx - 80):idx + 200]
                    printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
                    log(f"    Context: {printable}")
                    break
        except:
            pass

log("\n=== DONE - if nothing found above, config is in Electron internal state ===")
with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
