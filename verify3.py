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
    r = send_tcp({"cmd_id": f"v3_{name}", "command": cmd, "type": "wsl", "timeout": 12})
    out = r.get("stdout", "").strip()
    print(f"\n=== {name} (dur={r.get('duration_ms')}ms err={r.get('error','')!r}) ===")
    if out: print(out)

# 1. chatbot commit 时间线（最近活动）
run("chatbot_recent_commits_with_dates",
    "cd /home/administrator/projects/chatbot && git log --format='%h | %ci | %s' -15 2>/dev/null")

# 2. resonova commit 时间线
run("resonova_recent_commits_with_dates",
    "cd /home/administrator/projects/resonova && git log --format='%h | %ci | %s' -15 2>/dev/null")

# 3. 检查另一个 AI 说的 d98df28 / d2c86d3 是否在历史里
run("resonova_hash_d98df28",
    "cd /home/administrator/projects/resonova && git log --all --oneline 2>/dev/null | grep d98df28 || echo 'HASH_NOT_FOUND_in_any_branch'")
run("resonova_hash_d2c86d3",
    "cd /home/administrator/projects/resonova && git log --all --oneline 2>/dev/null | grep d2c86d3 || echo 'HASH_NOT_FOUND_in_any_branch'")

# 4. kokoro.py 集成完成度
run("kokoro_size",
    "wc -l /home/administrator/projects/chatbot/src/processors/tts/kokoro.py 2>/dev/null")
run("kokoro_refs",
    "grep -rn 'kokoro' /home/administrator/projects/chatbot/src --include='*.py' 2>/dev/null | head -10")
run("kokoro_root_dup",
    "ls -la /home/administrator/projects/chatbot/bot_mqtt.py /home/administrator/projects/chatbot/src/bot_mqtt.py 2>/dev/null")

# 5. 进程的 stdout 在哪（解释日志消失）
run("process_fds_bot_mqtt",
    "ls -la /proc/19521/fd/1 /proc/19521/fd/2 2>/dev/null")
run("process_fds_bot_runner",
    "ls -la /proc/19470/fd/1 /proc/19470/fd/2 2>/dev/null")
run("process_fds_stage_pool",
    "ls -la /proc/253/fd/1 /proc/253/fd/2 2>/dev/null")

# 6. 真正的日志位置（systemd? screen? nohup.out?）
run("recent_log_files",
    "find /home/administrator/projects/chatbot -name '*.log' -mtime -3 2>/dev/null | head -10")
run("recent_resonova_logs",
    "find /home/administrator/projects/resonova -name '*.log' -mtime -3 2>/dev/null | head -10")

# 7. stage_pool 实际部署位置（PID 253 工作目录）
run("stage_pool_cwd",
    "readlink /proc/253/cwd 2>/dev/null")
run("stage_pool_started",
    "ps -o pid,lstart,cmd -p 253 2>/dev/null")
run("bot_mqtt_started",
    "ps -o pid,lstart,cmd -p 19521 2>/dev/null")
