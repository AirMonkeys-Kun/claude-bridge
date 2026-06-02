"""Deep exploration of Claude-3p config - list ALL files + search EVERYWHERE"""
import os, sys
from pathlib import Path

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\config_explore2.txt"

def log(msg):
    print(msg)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(msg + "\n")

def write_binary_summary(filepath, rel):
    """Try to read first bytes of a binary file"""
    try:
        with open(filepath, "rb") as f:
            header = f.read(256)
        # Check for known formats
        if header[:3] == b'\xef\xbb\xbf':
            return "UTF-8 BOM text"
        if header[:2] in (b'\xff\xfe', b'\xfe\xff'):
            return "UTF-16 text"
        if header[:8] == b'\x53\x51\x4c\x69\x74\x65\x20\x66':  # SQLite format
            return "SQLite database"
        if header[:4] == b'\x08\x00\x00\x00':  # LevelDB log
            return "LevelDB log (.log)"
        if header[:4] == b'\x00\x00\x00\x00':  # LevelDB .ldb
            return "LevelDB table (.ldb)"
        if header[:2] == b'\x01\x00':
            return "NE/Binary"
        if header[:4] == b'\x50\x4b\x03\x04':  # PK
            return "ZIP/JAR"
        # Try to detect if it's text
        try:
            text_len = len(header.decode('utf-8'))
            return "UTF-8 text"
        except:
            hex_preview = ' '.join(f'{b:02x}' for b in header[:32])
            return f"Binary (hex: {hex_preview}...)"
    except:
        return "Cannot read"

log("="*60)
log("Claude-3p DEEP CONFIG EXPLORATION v2")
log("="*60)

base_dirs = [
    os.environ.get("LOCALAPPDATA", "") + "\\Claude-3p",
    os.environ.get("APPDATA", "") + "\\Claude-3p",
    os.environ.get("LOCALAPPDATA", "") + "\\Cowork",
    os.environ.get("APPDATA", "") + "\\Cowork",
    os.environ.get("PROGRAMDATA", "") + "\\Claude-3p",
    os.environ.get("PROGRAMDATA", "") + "\\Cowork",
]

# Add common paths manually
user = os.environ.get("USERPROFILE", "")
base_dirs.extend([
    user + "\\AppData\\Local\\Claude-3p",
    user + "\\AppData\\Roaming\\Claude-3p",
    user + "\\.claude",
    user + "\\AppData\\Local\\claude-desktop",
    user + "\\AppData\\Roaming\\claude-desktop",
])

# Search specifically for claude-code too
base_dirs.append(os.path.join(os.environ.get("LOCALAPPDATA", ""), "Claude-3p", "claude-code"))

for base in base_dirs:
    if os.path.isdir(base):
        log(f"\n{'='*60}")
        log(f"EXISTS: {base}")
        log(f"{'='*60}")

        # Full recursive listing
        for root, dirs, files in os.walk(base):
            depth = root.replace(base, "").count(os.sep)
            if depth > 6:
                continue
            rel = os.path.relpath(root, base) if root != base else "."

            # Show directories
            if rel != ".":
                log(f"[{rel}/]")

            for f in sorted(files):
                fpath = os.path.join(root, f)
                try:
                    fsize = os.path.getsize(fpath)
                    ftype = write_binary_summary(fpath, rel)
                    log(f"  {f} ({fsize:>10,} bytes) [{ftype}]")

                    # Read text files for workspace keywords
                    if "text" in ftype.lower() or f.endswith((".json", ".txt", ".log", ".cfg", ".conf", ".ini", ".xml", ".yaml", ".yml", ".toml")):
                        try:
                            with open(fpath, "r", encoding="utf-8", errors="ignore") as fp:
                                content = fp.read(50000)  # Read up to 50KB
                        except:
                            content = ""
                        if content:
                            for kw in ["wsl", "workspace", "folder", "mount", "selected",
                                      "wsl.localhost", "\\wsl", "ubuntu", "mounted", "userSelected",
                                      "add-dir", "project", "cowork"]:
                                idx = content.lower().find(kw)
                                if idx >= 0:
                                    start = max(0, idx - 80)
                                    end = min(len(content), idx + 80)
                                    ctx = content[start:end].replace('\n', '\\n').replace('\r', '')
                                    log(f"   >>> MATCH '{kw}' in {f}: ...{ctx}...")
                                    break
                except:
                    log(f"  {f} (ERROR: cannot read)")

        # Also list just the top-level
        log(f"\nTop-level contents:")
        for item in sorted(os.listdir(base)):
            item_path = os.path.join(base, item)
            if os.path.isdir(item_path):
                try:
                    sub = len(os.listdir(item_path))
                except:
                    sub = -1
                log(f"  📁 {item} ({sub} items)")
            else:
                log(f"  📄 {item}")

log("\n\n=== SEARCH COMPLETE ===")
print(f"\nResults saved to: {LOG}")
