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
    r = send_tcp({"cmd_id": f"v4_{name}", "command": cmd, "type": "wsl", "timeout": 12})
    out = r.get("stdout", "").strip()
    print(f"\n=== {name} (dur={r.get('duration_ms')}ms err={r.get('error','')!r}) ===")
    if out: print(out)

run("diff_summary", "cd /home/administrator/projects/chatbot && git diff --stat 2>/dev/null")
run("bot_mqtt_diff", "cd /home/administrator/projects/chatbot && git diff --unified=0 src/bot_mqtt.py 2>/dev/null | head -120")
run("mqtt_transport_diff", "cd /home/administrator/projects/chatbot && git diff src/processors/mqtt/mqtt_input_transport.py 2>/dev/null | grep -E '^(@@|\\+[^+]|-[^-])' | head -100")
run("newest_bot_mqtt_log", "ls -t /home/administrator/projects/chatbot/output/log/bot_mqtt-*.log 2>/dev/null | head -3")
run("bot_mqtt_log_tail", "tail -50 $(ls -t /home/administrator/projects/chatbot/output/log/bot_mqtt-*.log 2>/dev/null | head -1) 2>/dev/null")
run("bot_runner_log_tail", "tail -40 $(ls -t /home/administrator/projects/chatbot/output/log/bot_runner-*.log 2>/dev/null | head -1) 2>/dev/null")
run("nanomq_clients", "ss -tnp 2>/dev/null | grep ':1883' | head -15")
run("kokoro_in_env", "grep -i kokoro /home/administrator/projects/chatbot/.env 2>/dev/null | head -5")
run("kokoro_models", "find /home/administrator -name 'kokoro*' -type f 2>/dev/null | head -10")
