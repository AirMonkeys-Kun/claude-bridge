import subprocess

LOG = r"C:\Users\wsx\Desktop\claude-bridge\watcher\wmic_full.txt"

out = subprocess.check_output(
    'wmic process where "name=\'Claude.exe\'" get CommandLine /format:list 2>&1',
    shell=True, timeout=10, stderr=subprocess.STDOUT
).decode("utf-8", errors="replace")

with open(LOG, "w", encoding="utf-8") as f:
    f.write(out)
print(f"Output length: {len(out)} chars")
print(f"Saved to: {LOG}")
