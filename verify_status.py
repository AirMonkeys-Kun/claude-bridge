"""Verify project status via bridge wsl_pool (TCP 19850)."""
import json, socket, sys

HOST = "172.16.10.254"
PORT = 19850

def send_tcp(cmd, timeout=30):
    s = socket.socket()
    s.settimeout(timeout)
    s.connect((HOST, PORT))
    try:
        s.sendall((json.dumps(cmd) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk: break
            buf += chunk
        return json.loads(buf.decode("utf-8").strip())
    finally:
        try: s.close()
        except OSError: pass

# One composite bash command — runs in persistent wsl.exe, all output via stdout
diag = r'''
echo "===SECTION_1_NANOMQ==="
pgrep -af nanomq 2>/dev/null || echo "NOT_RUNNING"
echo "PORT_1883:"
ss -tlnp 2>/dev/null | grep ':1883' || echo "1883_NOT_LISTENING"
echo "PORT_3000:"
ss -tlnp 2>/dev/null | grep ':3000' || echo "3000_NOT_LISTENING"
echo "PORT_5173:"
ss -tlnp 2>/dev/null | grep ':5173' || echo "5173_NOT_LISTENING"

echo "===SECTION_2_SERVERPY==="
pgrep -af 'python.*server\.py' 2>/dev/null | head -5 || echo "server.py_NOT_RUNNING"
echo "ALL_PYTHON:"
pgrep -af python 2>/dev/null | head -10

echo "===SECTION_3_PROJECTS==="
ls /home/administrator/projects/ 2>/dev/null | head -20

echo "===SECTION_4_RESONOVA==="
cd /home/administrator/projects/resonova 2>/dev/null && {
    pwd
    echo "BRANCH: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "HEAD: $(git rev-parse --short HEAD 2>/dev/null)"
    echo "LAST_3_COMMITS:"
    git log --oneline -3 2>/dev/null
    echo "STATUS:"
    git status --short 2>/dev/null | head -15
    echo "REMOTES:"
    git remote -v 2>/dev/null | head -5
    echo "UNPUSHED:"
    git log @{u}.. --oneline 2>/dev/null | head -10 || echo "no upstream or all pushed"
} || echo "resonova_DIR_NOT_FOUND"

echo "===SECTION_5_CHATBOT==="
cd /home/administrator/projects/chatbot 2>/dev/null && {
    pwd
    echo "BRANCH: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "HEAD: $(git rev-parse --short HEAD 2>/dev/null)"
    echo "LAST_3_COMMITS:"
    git log --oneline -3 2>/dev/null
    echo "STATUS:"
    git status --short 2>/dev/null | head -20
    echo "DIFFSTAT:"
    git diff --stat 2>/dev/null | head -10
}

echo "===SECTION_6_LOGS==="
ls -la /home/administrator/projects/chatbot/output/log/ 2>/dev/null | tail -10 || echo "no log dir"

echo "===DONE==="
'''

r = send_tcp({
    "cmd_id": "verify_status_v1",
    "command": diag,
    "type": "wsl",
    "timeout": 25
})
print(f"channel={r.get('dispatch_channel')} exit={r.get('exit_code')} dur={r.get('duration_ms')}ms")
print("=" * 60)
print(r.get("stdout", ""))
if r.get("error"):
    print("ERROR:", r.get("error"))
