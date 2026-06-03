import re, os
import sys

# Try to read IndexedDB files - they might be locked but let's see
base = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\IndexedDB\app_localhost_0.indexeddb.leveldb"
seen = set()
for fname in os.listdir(base):
    if not (fname.endswith('.ldb') or fname.endswith('.log')):
        continue
    fpath = os.path.join(base, fname)
    try:
        with open(fpath, 'rb') as f:
            data = f.read()
    except PermissionError as e:
        print(f"SKIP:{fname}:{e}")
        continue
    except OSError as e:
        print(f"SKIP:{fname}:{e}")
        continue
    # First look for JSON-like content with workspace/folder keywords
    strs = re.findall(b'[\x20-\x7e]{10,}', data)
    matches = 0
    for s in strs:
        txt = s.decode('ascii', errors='ignore')
        if 'wsl' in txt.lower() or 'workspace' in txt.lower() or 'folder' in txt.lower() or 'directory' in txt.lower():
            if txt not in seen:
                seen.add(txt)
                print(f"{fname}: {txt[:200]}")
                matches += 1
                if matches >= 50:
                    break
    print(f"[{fname}: {matches} matches found]")
print("===SCAN DONE===")
