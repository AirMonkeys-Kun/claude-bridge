import re, os
import sys

# Search ALL leveldb files in the entire Claude-3p tree for path-like strings
root = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
all_matches = set()

for dirpath, dirnames, fnames in os.walk(root):
    for fname in fnames:
        if not (fname.endswith('.ldb') or fname.endswith('.log') or fname == 'Preferences' or fname == 'Local State' or fname == 'window-state.json' or fname.endswith('.json')):
            continue
        fpath = os.path.join(dirpath, fname)
        try:
            with open(fpath, 'rb') as f:
                data = f.read()
        except (PermissionError, OSError):
            continue

        # Extract all printable strings >= 6 chars
        strs = re.findall(b'[\x20-\x7e]{6,}', data)
        for s in strs:
            txt = s.decode('ascii', errors='ignore')
            # Look for Windows paths or UNC paths or any path-like string
            if ('\\' in txt and (txt.startswith('C:') or txt.startswith('D:') or txt.startswith('\\\\') or '\\Users\\' in txt or '\\home\\' in txt)):
                if txt not in all_matches:
                    all_matches.add(txt)
                    if len(all_matches) <= 200:
                        print(txt)
            # Look specifically for wsl.localhost
            if 'wsl' in txt.lower() and 'local' in txt.lower():
                if txt not in all_matches:
                    all_matches.add(txt)
                    if len(all_matches) <= 200:
                        print("WSL:", txt)

print(f"\n=== Total unique matches: {len(all_matches)} ===")
