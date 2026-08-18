"""Apply .env fix: backup, append 3 S3 vars if missing, verify, find bot_mqtt launch method."""
import os
from dotenv import load_dotenv
load_dotenv("/home/administrator/projects/chatbot/.env")

ENV_PATH = "/home/administrator/projects/chatbot/.env"

# 1. Backup
import shutil
import time
bak = f"{ENV_PATH}.bak.{time.strftime('%Y%m%d_%H%M%S')}"
shutil.copy2(ENV_PATH, bak)
print(f"[BACKUP] copied to {bak}")

# 2. Read current
with open(ENV_PATH, "r", encoding="utf-8") as f:
    content = f.read()

# 3. Add missing keys
to_add = []
if "AWS_BUCKET_NAME" not in os.environ or not os.getenv("AWS_BUCKET_NAME"):
    to_add.append("AWS_BUCKET_NAME=zeb-audio")
if not os.getenv("S3_AUDIO_BASE_PATH"):
    to_add.append("S3_AUDIO_BASE_PATH=introductions")
if not os.getenv("S3_PUBLIC_BUCKET"):
    to_add.append("S3_PUBLIC_BUCKET=true")

if to_add:
    addition = "\n\n# S3 Audio Storage for Introduction Audio (added by claude-bridge)\n" + "\n".join(to_add) + "\n"
    with open(ENV_PATH, "a", encoding="utf-8") as f:
        f.write(addition)
    print(f"[APPLIED] appended {len(to_add)} keys: {to_add}")
else:
    print("[SKIP] all keys already present")

# 4. Verify (re-read .env fresh, not from old os.environ cache)
import importlib
importlib.reload(importlib.import_module('dotenv'))
fresh_env = {}
with open(ENV_PATH, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        fresh_env[k.strip()] = v.strip().strip('"')

print("\n[VERIFY] S3 keys in .env after edit:")
for k in ("AWS_BUCKET_NAME", "S3_AUDIO_BASE_PATH", "S3_PUBLIC_BUCKET", "S3_BASE_URL",
          "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION"):
    v = fresh_env.get(k, "<MISSING>")
    if k == "AWS_SECRET_ACCESS_KEY" and v != "<MISSING>":
        v = v[:8] + "..."
    print(f"  {k} = {v}")

# 5. Find bot_mqtt launch method (PID 19521)
import subprocess
print("\n[LAUNCH] bot_mqtt PID 19521 details:")
try:
    out = subprocess.check_output(["ps", "-o", "pid,ppid,lstart,cmd", "-p", "19521"],
                                  text=True, stderr=subprocess.DEVNULL)
    print(out)
except subprocess.CalledProcessError as e:
    print(f"  ps failed: {e}")

# Check if it's a systemd service
try:
    out = subprocess.check_output(["systemctl", "status", "bot_mqtt"],
                                  text=True, stderr=subprocess.DEVNULL, timeout=3)
    if "active" in out.lower():
        print("[SYSTEMD] bot_mqtt is a systemd service:")
        print(out[:500])
except Exception:
    pass

# Check parent process of 19521
try:
    ppid_out = subprocess.check_output(["ps", "-o", "ppid=", "-p", "19521"], text=True).strip()
    if ppid_out:
        ppid = int(ppid_out)
        par_out = subprocess.check_output(["ps", "-o", "pid,cmd", "-p", str(ppid)],
                                          text=True, stderr=subprocess.DEVNULL)
        print(f"[PARENT] PID 19521's parent:")
        print(par_out)
except Exception as e:
    print(f"  parent lookup failed: {e}")

# Check for restart script
import os as _os
for cand in ("/home/administrator/projects/chatbot/scripts/restart_bot_mqtt.sh",
             "/home/administrator/projects/chatbot/restart_bot_mqtt.sh"):
    if _os.path.exists(cand):
        print(f"[SCRIPT] found: {cand}")
        with open(cand) as f:
            print(f.read()[:600])
        break
