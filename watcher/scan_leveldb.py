import re
import os
import sys

# Search all leveldb files for strings containing workspace/folder/cowork paths
base = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p\Local Storage\leveldb"
seen = set()
for fname in os.listdir(base):
    if not (fname.endswith('.ldb') or fname.endswith('.log')):
        continue
    fpath = os.path.join(base, fname)
    try:
        with open(fpath, 'rb') as f:
            data = f.read()
    except PermissionError:
        continue
    # Extract strings >= 8 chars
    strs = re.findall(b'[\x20-\x7e]{8,}', data)
    for s in strs:
        txt = s.decode('ascii', errors='ignore')
        if any(kw in txt.lower() for kw in ['\\wsl', 'workspace', 'folder', 'cowork', 'selecteddir', 'directory', 'mount', 'unc', 'localhost']):
            if txt not in seen:
                seen.add(txt)
                print(txt)
