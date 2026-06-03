import re, os

# Only search in specific directories, skip cache/network/session-level blobs
root = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
skip_dirs = {'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Crashpad', 'sentry', 'fcache', 'Network', 'blob_storage', 'Dictionaries', 'SharedStorage', 'SharedStorage-wal', 'DIPS', 'DIPS-wal', 'Shared Dictionary', 'WebStorage', 'Session Storage', 'logs', 'vm_bundles', 'lockfile'}

hit_files = set()
for dirpath, dirnames, fnames in os.walk(root):
    # Skip large cache directories
    basename = os.path.basename(dirpath)
    if basename in skip_dirs:
        dirnames.clear()
        continue

    for fname in fnames:
        fpath = os.path.join(dirpath, fname)
        try:
            with open(fpath, 'rb') as f:
                data = f.read()
        except:
            continue

        # Look for wsl.localhost
        if b'wsl' in data.lower() or b'\\\\wsl' in data:
            hits = list(re.finditer(b'.{0,30}(\\\\wsl\\.localhost)[^\\0]{0,200}', data, re.IGNORECASE))
            if hits:
                for h in hits:
                    print(f"{fname}: {h.group()[:150]}")
                hit_files.add(fpath)

        # Also look for path-like JSON values in non-binary files (< 100KB)
        if fname.endswith('.json') or fname.endswith('.log') or fname == 'Preferences':
            txt = data.decode('utf-8', errors='replace')
            if 'wsl.localhost' in txt.lower() or '\\\\wsl' in txt:
                for line in txt.split('\n'):
                    if 'wsl.localhost' in line.lower() or '\\\\wsl' in line:
                        cleaned = line.strip()[:300]
                        print(f"{fname}: {cleaned}")

if not hit_files:
    print("NO MATCHES FOUND")
print(f"===SCAN DONE===")
