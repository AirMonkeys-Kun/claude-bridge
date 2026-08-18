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
    r = send_tcp({"cmd_id": f"lv2_{name}", "command": cmd, "type": "wsl", "timeout": 15})
    out = r.get("stdout", "").strip()
    print(f"\n=== {name} (dur={r.get('duration_ms')}ms err={r.get('error','')!r}) ===")
    if out: print(out)

# feature/intro-audio-storage 分支内容
run("branch_exists_check", "cd /home/administrator/projects/chatbot && git rev-parse --verify origin/feature/intro-audio-storage 2>&1 | head -3")
run("branch_last_commit", "cd /home/administrator/projects/chatbot && git log origin/feature/intro-audio-storage --oneline -10 2>/dev/null")
run("branch_authors", "cd /home/administrator/projects/chatbot && git log origin/feature/intro-audio-storage --format='%an' 2>/dev/null | sort -u")

# .env.example 在这个分支
run("env_example_in_branch", "cd /home/administrator/projects/chatbot && git show origin/feature/intro-audio-storage:.env.example 2>/dev/null | grep -iE 'aws|s3|bucket|audio' | head -20")

# audio_generation_service.py 在分支 (前 80 行 + AWS init 部分)
run("aws_init_in_branch", "cd /home/administrator/projects/chatbot && git show origin/feature/intro-audio-storage:src/services/audio_generation_service.py 2>/dev/null | grep -n -A 2 'AWS_BUCKET\\|S3_\\|bucket_name\\|_create_s3_client' | head -40")

# 关键 commit 1ae35e7 改了什么
run("commit_1ae35e7_files", "cd /home/administrator/projects/chatbot && git show --stat 1ae35e7 2>/dev/null | head -20")
run("commit_1ae35e7_env", "cd /home/administrator/projects/chatbot && git show 1ae35e7 -- .env.example 2>/dev/null | head -40")

# 关键 commit 484aade（最初实现）改了什么
run("commit_484aade_files", "cd /home/administrator/projects/chatbot && git show --stat 484aade 2>/dev/null | head -25")
run("commit_484aade_env", "cd /home/administrator/projects/chatbot && git show 484aade -- .env.example 2>/dev/null | head -50")

# 当前 main 分支跟 feature/intro-audio-storage 的关系
run("branch_diff_summary", "cd /home/administrator/projects/chatbot && git log --oneline origin/feature/intro-audio-storage..origin/main 2>/dev/null | head -10")
run("branch_merge_status", "cd /home/administrator/projects/chatbot && git branch -a --contains 1ae35e7 2>/dev/null | head -10")

# 看分支的 README/docs 是否解释 S3 配置
run("branch_readme_audio", "cd /home/administrator/projects/chatbot && git show origin/feature/intro-audio-storage:docs/audio_generation.md 2>/dev/null | head -40 || echo 'no docs/audio_generation.md'")
run("branch_docs_list", "cd /home/administrator/projects/chatbot && git ls-tree -r origin/feature/intro-audio-storage --name-only 2>/dev/null | grep -iE 'audio|s3|storage' | head -15")
