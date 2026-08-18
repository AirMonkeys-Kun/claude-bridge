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
    r = send_tcp({"cmd_id": f"v5_{name}", "command": cmd, "type": "wsl", "timeout": 12})
    out = r.get("stdout", "").strip()
    print(f"\n=== {name} (dur={r.get('duration_ms')}ms err={r.get('error','')!r}) ===")
    if out: print(out)

# 1. .env 里 AWS / S3 相关
run("env_aws_s3", "grep -iE 'aws|s3|bucket|minio|cloudflare|r2' /home/administrator/projects/chatbot/.env 2>/dev/null | grep -v '^#' | head -30")

# 2. .env 文件清单（不打印值，只看 key 名）
run("env_keys", "grep -E '^[A-Z_]+=' /home/administrator/projects/chatbot/.env 2>/dev/null | awk -F= '{print $1}' | sort | head -80")

# 3. resolve_audio_reference 实现
run("resolve_fn_search", "grep -rn 'AWS_BUCKET_NAME\\|resolve_audio_reference\\|s3://' /home/administrator/projects/chatbot/src --include='*.py' 2>/dev/null | head -30")

# 4. audio_generation_service.py 关键部分
run("audio_svc_buckets", "grep -n 'AWS_\\|S3_\\|BUCKET\\|s3://' /home/administrator/projects/chatbot/src/services/audio_generation_service.py 2>/dev/null | head -40")

# 5. 看是否有专门的 aws config
run("aws_config_files", "find /home/administrator/projects/chatbot/src -type f \\( -name '*aws*' -o -name '*s3*' -o -name '*storage*' -o -name '*bucket*' \\) 2>/dev/null | head -20")

# 6. 配置总入口（settings/config）
run("config_files", "find /home/administrator/projects/chatbot/src -maxdepth 3 -type f \\( -name 'config.py' -o -name 'settings.py' -o -name '*.env.py' \\) 2>/dev/null | head -10")

# 7. 看 chatbot 用的 .env 是哪个（可能 .env.production / .env.local）
run("env_files", "ls -la /home/administrator/projects/chatbot/.env* 2>/dev/null")
