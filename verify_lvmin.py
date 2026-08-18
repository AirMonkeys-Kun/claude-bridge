import json, socket

def send_tcp(cmd, timeout=15):
    s = socket.socket(); s.settimeout(timeout); s.connect(("172.16.10.254", 19850))
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

def run(name, cmd):
    r = send_tcp({"cmd_id": f"vlv_{name}", "command": cmd, "type": "wsl", "timeout": 15})
    out = r.get("stdout", "").strip()
    print(f"\n=== {name} (dur={r.get('duration_ms')}ms err={r.get('error','')!r}) ===")
    if out: print(out)

# 找 lvmin 同事的所有分支
run("chatbot_branches_lvmin",
    "cd /home/administrator/projects/chatbot && git branch -a 2>/dev/null | grep -iE 'lvmin|lv_|/lv' | head -20")
run("chatbot_all_authors",
    "cd /home/administrator/projects/chatbot && git log --all --format='%an' 2>/dev/null | sort -u | head -20")
run("chatbot_lvmin_commits",
    "cd /home/administrator/projects/chatbot && git log --all --author='lvmin' --format='%h | %an | %ci | %s' 2>/dev/null | head -20")

run("resonova_branches_lvmin",
    "cd /home/administrator/projects/resonova && git branch -a 2>/dev/null | grep -iE 'lvmin|lv_|/lv' | head -20")
run("resonova_all_authors",
    "cd /home/administrator/projects/resonova && git log --all --format='%an' 2>/dev/null | sort -u | head -20")
run("resonova_lvmin_commits",
    "cd /home/administrator/projects/resonova && git log --all --author='lvmin' --format='%h | %an | %ci | %s' 2>/dev/null | head -20")

# 搜任何项目里跟 AWS_BUCKET_NAME 配置相关的 commit
run("chatbot_commits_aws_bucket",
    "cd /home/administrator/projects/chatbot && git log --all --oneline -S 'AWS_BUCKET_NAME' 2>/dev/null | head -10")
run("chatbot_commits_s3_audio",
    "cd /home/administrator/projects/chatbot && git log --all --oneline -S 'S3_AUDIO_BASE_PATH' 2>/dev/null | head -10")

# 看所有包含 audio/storage 配置的分支
run("chatbot_branches_audio",
    "cd /home/administrator/projects/chatbot && git branch -a 2>/dev/null | grep -iE 'audio|tts|s3' | head -10")

# 所有 collaborator 的最近 commit（找 lvmin）
run("chatbot_recent_all_authors",
    "cd /home/administrator/projects/chatbot && git log --all --since='30 days ago' --format='%h | %an | %s' 2>/dev/null | head -30")
