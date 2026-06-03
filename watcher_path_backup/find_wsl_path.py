import re, os
root = r"C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p"
for dirpath, dirnames, fnames in os.walk(root):
    for fname in fnames:
        fpath = os.path.join(dirpath, fname)
        try:
            with open(fpath, 'rb') as f:
                data = f.read()
        except:
            continue
        # Search specifically for wsl.localhost
        if b'wsl.localhost' in data.lower() or b'wsl' in data.lower():
            print(f"MATCH in {fname}:")
            for i, s in enumerate(re.findall(b'.{0,50}wsl.{0,100}', data, re.IGNORECASE)):
                print(f"  [{i}] {s[:200]}")
            if fname.endswith('.json'):
                txt = data.decode('utf-8', errors='replace')
                for line in txt.split('\n'):
                    if 'wsl' in line.lower():
                        print(f"  JSON: {line[:200]}")
