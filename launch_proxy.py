"""Launch proxy_server.py as a detached background process."""
import subprocess
import sys
import os

script = os.path.join(os.path.dirname(__file__), "proxy_server.py")
log = os.path.join(os.path.dirname(__file__), "launch.log")

with open(log, "w") as f:
    f.write(f"Launching: {script}\n")

proc = subprocess.Popen(
    [sys.executable, script],
    stdout=open(log, "a"),
    stderr=subprocess.STDOUT,
    creationflags=subprocess.CREATE_NO_WINDOW | subprocess.DETACHED_PROCESS,
)

with open(log, "a") as f:
    f.write(f"PID={proc.pid}\n")

print(f"PID={proc.pid}")
