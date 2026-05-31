import re, os, sys
root = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
found = False
for dirpath, dirnames, fnames in os.walk(root):
    # Skip giant cache dirs
    bn = os.path.basename(dirpath)
    if bn in ('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Crashpad', 'sentry', 'fcache'):
        dirnames.clear()
        continue
    for fname in fnames:
        fpath = os.path.join(dirpath, fname)
        try:
            with open(fpath, 'rb') as f:
                data = f.read(1048576)  # Read max 1MB
        except:
            continue
        idx = data.lower().find(b'wsl')
        if idx >= 0:
            context = data[max(0,idx-50):idx+200]
            print(f"WSL FOUND in {fname}: {context}")
            found = True
if not found:
    print("NO WSL matches found")
print("DONE")
