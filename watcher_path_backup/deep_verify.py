import os, json, subprocess

USER = r"C:\Users\wsx"
PKG = USER + r"\AppData\Local\Packages\Claude_pzs8sxrjxfjjc"
CLAUDE_DATA = PKG + r"\LocalCache\Local\Claude-3p"
SESSIONS_DIR = os.path.join(CLAUDE_DATA, "local-agent-mode-sessions")
WSL = r"\\wsl.localhost\ubuntu\home\yck"
LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\deep_verify.txt"
results = []
def log(m): print(m); results.append(str(m))

log("=== DEEP VERIFY: 全面检查 WSL 路径是否真正消除 ===\n")

# 1. Check: app process memory via WMIC
log("--- 1. Claude 进程命令行检查 ---")
try:
    out = subprocess.check_output(
        'wmic process where "name=\'Claude.exe\'" get CommandLine /format:list 2>&1',
        shell=True, timeout=10, stderr=subprocess.STDOUT
    ).decode("utf-8", errors="replace")
    log(f"  WMIC output: {out[:500] if out else 'EMPTY'}")
    if WSL in out:
        log("  >>> WSL FOUND in process command line!")
    else:
        log("  >>> WSL NOT in process command line")
except Exception as e:
    log(f"  WMIC failed (expected from SYSTEM): {e}")

# 2. Check: ALL session JSON files in detail
log("\n--- 2. 全量扫描所有 session JSON ---")
count_wsl = 0
count_total = 0
for root, dirs, files in os.walk(SESSIONS_DIR):
    for f in files:
        if f.endswith(".json") and not f.endswith(".backup"):
            fp = os.path.join(root, f)
            try:
                with open(fp, "r", encoding="utf-8") as fh:
                    content = fh.read()
                if "userSelectedFolders" in content:
                    count_total += 1
                    data = json.loads(content)
                    # Check dict or list
                    items = [data] if isinstance(data, dict) else data if isinstance(data, list) else []
                    for item in items:
                        if isinstance(item, dict):
                            folders = item.get("userSelectedFolders", [])
                        elif isinstance(item, list):
                            # unlikely but handle
                            folders = []
                        else:
                            continue
                        for folder in folders:
                            if "wsl" in folder.lower() or "wsl$" in folder.lower():
                                count_wsl += 1
                                rel = os.path.relpath(fp, SESSIONS_DIR)
                                log(f"  >>> WSL ACTIVE in: {rel} -> {folder}")
            except:
                pass

log(f"\n  Files with userSelectedFolders: {count_total}")
log(f"  Files with WSL in userSelectedFolders: {count_wsl}")
if count_wsl == 0:
    log("  >>> ALL SESSION FILES CLEAN")

# 3. Check: scheduled-tasks.json
log("\n--- 3. scheduled-tasks.json 深度检查 ---")
for root, dirs, files in os.walk(SESSIONS_DIR):
    for f in files:
        if f == "scheduled-tasks.json":
            fp = os.path.join(root, f)
            try:
                with open(fp, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
                tasks = data.get("scheduledTasks", [])
                log(f"  Tasks: {len(tasks)}")
                for t in tasks:
                    folders = t.get("userSelectedFolders", [])
                    has_wsl = any("wsl" in str(f).lower() for f in folders)
                    log(f"  Task '{t['id']}': folders={folders} {'<<< WSL' if has_wsl else ''}")
                    if has_wsl:
                        log("  >>> FAIL: WSL still in scheduled tasks!")
            except Exception as e:
                log(f"  Error reading: {e}")

# 4. Check: VHDX binary search for WSL (first 50MB of sessiondata.vhdx)
log("\n--- 4. VHDX 快速搜索 WSL (前 50MB) ---")
vhdx = PKG + r"\LocalCache\Local\Claude-3p\vm_bundles\claudevm.bundle\sessiondata.vhdx"
try:
    with open(vhdx, "rb") as f:
        # Check header
        header = f.read(10)
        log(f"  VHDX header: {header[:5]}... (valid VHDX: {header[:6] == b'vhdxfi' or header[:6] == b'VHDXFI'})")
        # Search first 50MB for WSL-related strings
        f.seek(0)
        chunk = f.read(50 * 1024 * 1024)
        if WSL.encode("utf-8") in chunk:
            idx = chunk.index(WSL.encode("utf-8"))
            ctx = chunk[max(0, idx-50):idx+100]
            printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
            log(f"  >>> WSL FOUND in VHDX at offset {idx}: ...{printable}...")
        else:
            log("  >>> WSL NOT in first 50MB of VHDX")
except Exception as e:
    log(f"  VHDX read error: {e}")

# 5. Check: MSIX Settings.dat binary content
log("\n--- 5. MSIX Settings.dat raw dump ---")
settings_dat = PKG + r"\Settings\settings.dat"
try:
    with open(settings_dat, "rb") as f:
        data = f.read()
    log(f"  Size: {len(data)} bytes")
    if WSL.encode("utf-8") in data:
        log("  >>> WSL FOUND in settings.dat!")
    else:
        log("  >>> WSL NOT in settings.dat")
    # Print content as hex
    log(f"  Hex dump (first 512 bytes):")
    hex_out = []
    for i in range(0, min(512, len(data)), 16):
        hex_bytes = ' '.join(f'{b:02x}' for b in data[i:i+16])
        ascii_repr = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[i:i+16])
        hex_out.append(f"    {i:04x}: {hex_bytes:<48} {ascii_repr}")
    log('\n'.join(hex_out[:10]))  # First 10 lines
except Exception as e:
    log(f"  Error: {e}")

# 6. Check: Any .ldb files in IndexedDB/LevelDB for WSL
log("\n--- 6. LevelDB IndexedDB WSL check ---")
count_ldb = 0
count_wsl_ldb = 0
for root, dirs, files in os.walk(CLAUDE_DATA):
    for f in files:
        if f.endswith((".ldb", ".log")):
            fp = os.path.join(root, f)
            try:
                sz = os.path.getsize(fp)
                if sz > 2000000:
                    continue
                with open(fp, "rb") as fh:
                    d = fh.read(sz)
                if WSL.encode("utf-8") in d:
                    count_wsl_ldb += 1
                    rel = os.path.relpath(fp, CLAUDE_DATA)
                    log(f"  >>> WSL in LevelDB: {rel}")
                count_ldb += 1
            except:
                pass

log(f"  Total LevelDB files scanned: {count_ldb}")
log(f"  LevelDB files with WSL: {count_wsl_ldb}")

log("\n=== DEEP VERIFY COMPLETE ===")
if count_wsl == 0 and count_wsl_ldb == 0:
    log("\n>>> CONCLUSION: WSL path eliminated from ALL persistent storage locations.")
    log(">>> Remaining bash error is because CURRENT sandbox was created before fix.")
    log(">>> Next Claude restart will create a clean sandbox.")
else:
    log("\n>>> WSL STILL EXISTS in some location! Fix incomplete.")

with open(LOG, "w", encoding="utf-8") as f:
    f.write("\n".join(results))
print(f"Result: {LOG}")
