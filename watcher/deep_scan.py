"""Deep scan for workspace mount config in Claude Desktop data."""
import os, re, json

target_dirs = [
    r'C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\Claude-3p',
    r'C:\Users\wsx\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude',
    r'C:\Users\wsx\AppData\Local\Claude-3p',
]

# Patterns to search in binary/text data
patterns = [
    rb'\\\\wsl\.localhost',  # UNC path
    rb'wsl\.localhost',      # WSL hostname
    rb'ubuntu[\\\\/]home[\\\\/]yck',  # The specific path
    rb'selected.?folder',    # JSON key
    rb'workspace.?folder',   # JSON key
    rb'userSelectedFolder',  # camelCase version
    rb'added.?user.?selected.?folder',  # Log entry
    rb'FileSystemWatcher',   # Related to watcher errors
    rb'Failed to create watcher',  # Error message
    rb'\\\\wsl',             # Any WSL UNC path
]

# Also search for JSON patterns
json_patterns = [
    '"wsl', 'workspace', '"mount', 'selectedFolder', 'selected_folder',
    'userFolders', 'workspaceFolders', 'mountedFolders', 'fileSystemWatcher',
    'wsl.localhost', 'local-agent-mode', 'sessionConfig'
]

found_any = False

for base in target_dirs:
    if not os.path.exists(base):
        print(f"SKIP: {base} (not found)")
        continue
    print(f"\n=== SCANNING: {base} ===")

    for root, dirs, files in os.walk(base):
        # Skip session dirs and caches
        dirs[:] = [d for d in dirs if d != 'local-agent-mode-sessions' and not d.startswith('local_')
                   and d not in ('Cache', 'Code Cache', 'GPUCache', 'crashpad', 'log')]

        for fname in files:
            fpath = os.path.join(root, fname)
            try:
                size = os.path.getsize(fpath)
                if size == 0 or size > 50000000:  # Skip empty or >50MB
                    continue

                # Read as binary
                with open(fpath, 'rb') as f:
                    data = f.read()

                # Check binary patterns
                for pat in patterns:
                    if pat in data:
                        # Find the context around the match
                        idx = data.index(pat)
                        start = max(0, idx - 100)
                        end = min(len(data), idx + 200)
                        context = data[start:end]
                        try:
                            ctx_str = context.decode('utf-8', errors='replace')
                        except:
                            ctx_str = repr(context[:100])
                        print(f"\n>>> BINARY HIT: {fpath} (offset {idx})")
                        print(f"  Content: {ctx_str}")
                        found_any = True
                        break

                # Also check for JSON patterns in smaller files
                if size < 5000000 and (fname.endswith('.json') or fname.endswith('.log') or fname.endswith('.txt')):
                    try:
                        text = data.decode('utf-8', errors='replace')
                        for pat in json_patterns:
                            if pat in text:
                                # Find the line containing the pattern
                                for i, line in enumerate(text.split('\n')):
                                    if pat in line:
                                        print(f"\n>>> TEXT HIT: {fpath}:{i+1}")
                                        print(f"  {line.strip()[:200]}")
                                        found_any = True
                                        break
                    except:
                        pass

            except (PermissionError, FileNotFoundError, OSError) as e:
                pass  # Skip locked/access denied files

if not found_any:
    print("\n=== NO MATCHES FOUND ===")
else:
    print("\n=== DONE ===")
