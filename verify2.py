import json, socket, sys

def send_tcp(cmd, timeout=15):
    s = socket.socket()
    s.settimeout(timeout)
    s.connect(("172.16.10.254", 19850))
    try:
        s.sendall((json.dumps(cmd) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk: break
            buf += chunk
        return json.loads(buf.decode().strip())
    finally:
        try: s.close()
        except: pass

cmds = [
    ("python_procs", "pgrep -af python 2>/dev/null | head -20"),
    ("chatbot_procs", "pgrep -af chatbot 2>/dev/null | head -10"),
    ("projects", "ls /home/administrator/projects/ 2>/dev/null"),
    ("resonova_head", "cd /home/administrator/projects/resonova 2>/dev/null && git rev-parse --short HEAD 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null"),
    ("resonova_log", "cd /home/administrator/projects/resonova 2>/dev/null && git log --oneline -5 2>/dev/null"),
    ("resonova_status", "cd /home/administrator/projects/resonova 2>/dev/null && git status --short 2>/dev/null | head -20"),
    ("resonova_remote", "cd /home/administrator/projects/resonova 2>/dev/null && git remote -v 2>/dev/null"),
    ("chatbot_head", "cd /home/administrator/projects/chatbot 2>/dev/null && git rev-parse --short HEAD 2>/dev/null && git rev-parse --abbrev-ref HEAD 2>/dev/null"),
    ("chatbot_log", "cd /home/administrator/projects/chatbot 2>/dev/null && git log --oneline -5 2>/dev/null"),
    ("chatbot_status", "cd /home/administrator/projects/chatbot 2>/dev/null && git status --short 2>/dev/null | head -20"),
    ("chatbot_diffstat", "cd /home/administrator/projects/chatbot 2>/dev/null && git diff --stat 2>/dev/null | head -15"),
    ("chatbot_logs", "ls -la /home/administrator/projects/chatbot/output/log/ 2>/dev/null | tail -10"),
    ("stage_pool_branches", "cd /home/administrator/projects/chatbot 2>/dev/null && git branch -a 2>/dev/null | head -20"),
    ("stage_pool_search", "cd /home/administrator/projects/chatbot 2>/dev/null && git log --all --oneline 2>/dev/null | grep -i stage | head -10"),
]

results = {}
for name, cmd in cmds:
    r = send_tcp({"cmd_id": f"v2_{name}", "command": cmd, "type": "wsl", "timeout": 12})
    out = r.get("stdout", "").strip()
    err = r.get("error", "")
    ch = r.get("dispatch_channel", "?")
    print(f"\n--- {name} (ch={ch} dur={r.get('duration_ms')}ms exit={r.get('exit_code')} err={err!r}) ---")
    if out:
        print(out)
