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
    r = send_tcp({"cmd_id": f"v6_{name}", "command": cmd, "type": "wsl", "timeout": 12})
    out = r.get("stdout", "").strip()
    print(f"\n=== {name} (dur={r.get('duration_ms')}ms err={r.get('error','')!r}) ===")
    if out: print(out)

# resolve_audio_reference 函数实现（130-200 行）
run("resolve_fn_body", "sed -n '50,210p' /home/administrator/projects/chatbot/src/services/audio_generation_service.py 2>/dev/null")

# 看 S3_BASE_URL / S3_PUBLIC_BUCKET / S3_AUDIO_BASE_PATH 是否在 .env
run("env_s3_threepart", "grep -iE 'S3_BASE_URL|S3_PUBLIC_BUCKET|S3_AUDIO_BASE_PATH|AWS_BUCKET_NAME|zeb-audio' /home/administrator/projects/chatbot/.env 2>/dev/null")

# 数据库里的 audio_url 字段（看 figurine introduction 表的 URL）
run("mysql_check_zeb_audio", "grep -E 'MYSQL_|DB_|DATABASE' /home/administrator/projects/chatbot/.env 2>/dev/null | grep -v SECRET | head -10")

# .env.example 看 AWS_BUCKET_NAME 是否在
run("env_example_aws", "grep -iE 'AWS_BUCKET|S3_BASE|S3_PUBLIC|S3_AUDIO' /home/administrator/projects/chatbot/.env.example 2>/dev/null")

# 看 zeb-audio bucket 哪里来的（数据库字段？）
run("zeb_audio_refs", "grep -rn 'zeb-audio' /home/administrator/projects/chatbot/src --include='*.py' 2>/dev/null | head -10")

# 看 boto3 client 初始化需要什么
run("boto3_init", "sed -n '60,90p' /home/administrator/projects/chatbot/src/services/audio_generation_service.py 2>/dev/null")
