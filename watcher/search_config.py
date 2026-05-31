"""Search Claude Desktop directories for config files containing workspace/mount info."""
import os, json, glob

base_dirs = [
    r'C:\Users\wsx\AppData\Local\Claude-3p',
    r'C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p',
    r'C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming',
    r'C:\Users\wsx\AppData\Roaming\Claude',
]

found_files = []

for base in base_dirs:
    if not os.path.exists(base):
        continue
    for root, dirs, files in os.walk(base):
        # Skip large session directories and logs
        skip_dirs = ['local-agent-mode-sessions', 'logs', 'Cache', 'Code Cache', 'GPUCache', 'crashpad']
        dirs[:] = [d for d in dirs if d not in skip_dirs and not d.startswith('local_')]

        for f in files:
            ext = os.path.splitext(f)[1].lower()
            if ext in ('.json', '.xml', '.db', '.sqlite', '.ldb', '.log'):
                fpath = os.path.join(root, f)
                size = os.path.getsize(fpath)
                found_files.append({'path': fpath, 'size': size})

                # For JSON files, check content for relevant keywords
                if ext == '.json' and size < 500000:
                    try:
                        with open(fpath, 'rb') as fh:
                            content = fh.read().decode('utf-8', errors='replace')
                        keywords = ['wsl', 'workspace', 'mount', 'folder', 'selected', 'unc', 'ubuntu']
                        if any(k in content.lower() for k in keywords):
                            print(f'>>> HIT: {fpath} ({size} bytes)')
                    except:
                        pass

print(f'\n--- Total files found: {len(found_files)} ---')
# Print smallest and largest
found_files.sort(key=lambda x: x['size'])
if found_files:
    print(f'Smallest: {found_files[0]["path"]} ({found_files[0]["size"]}B)')
    print(f'Largest: {found_files[-1]["path"]} ({found_files[-1]["size"]//1024}KB)')
