#!/usr/bin/env python3
"""Check WSL state directly (no nested wsl calls)."""
import subprocess, os

def run(cmd):
    return subprocess.run(
        ["bash", "-c", cmd], capture_output=True, text=True, timeout=30
    )

# 1. Test scripts in /tmp
r = run("ls -la /tmp/*.py 2>&1; echo '==='; ls -la /tmp/*.wav 2>&1")
print("=== /tmp scripts & test audio ===")
print(r.stdout + r.stderr)

# 2. Server processes
r = run("pgrep -a python3 2>&1 | head -30")
print("=== Python3 processes ===")
print(r.stdout + r.stderr)

r = run("pgrep -a uvicorn 2>&1")
print("=== Uvicorn ===")
print(r.stdout + r.stderr)

# 3. Test platform endpoint
r = run("curl -s http://localhost:8765/api/status 2>&1 || echo 'NO_SERVER'")
print("=== Test platform ===")
print(r.stdout + r.stderr)

# 4. Bot service
r = run("systemctl status bot_mqtt.service 2>&1 | head -20")
print("=== Bot service ===")
print(r.stdout + r.stderr)

# 5. MQTT broker
r = run("timeout 3 mosquitto_sub -h localhost -t 'resonova/status' -C 1 2>&1 || echo 'MOSQUITTO_NO_RESPONSE'")
print("=== MQTT broker test ===")
print(r.stdout + r.stderr)

print("\n=== DONE ===")
