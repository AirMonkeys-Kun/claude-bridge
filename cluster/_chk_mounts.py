import subprocess, json
r=subprocess.run(['cat','/proc/mounts'], capture_output=True, text=True)
lines=[l for l in r.stdout.split(chr(10)) if '9p' in l.lower() or 'claude' in l.lower() or 'plan9' in l.lower()]
if lines:
    for l in lines: print(l)
else:
    # check all mounts for anything relevant
    for l in r.stdout.split(chr(10))[:50]:
        if 'fuse' in l.lower() or 'virtio' in l.lower() or 'share' in l.lower():
            print(l)
    print('---all_mounts---')
    for l in r.stdout.split(chr(10))[:30]: print(l)