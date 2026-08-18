"""Trigger figurine introduction via MQTT and check if S3 audio URL resolves (no Kokoro fallback)."""
import os, json, time, glob
from dotenv import load_dotenv
load_dotenv("/home/administrator/projects/chatbot/.env")
import paho.mqtt.client as mqtt
try:
    from paho.mqtt.enums import CallbackAPIVersion
    client = mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION2)
except Exception:
    client = mqtt.Client()

# Publish
client.connect(os.getenv("MQTT_HOST", "localhost"), int(os.getenv("MQTT_PORT", "1883")), 60)
client.loop_start()

device_id = "sim-test-s3fix"
session_id = f"s3fix-{int(time.time())}"
payload = {
    "turn_proto": 1,
    "audio": {"codec": "opus", "sr": 16000, "channels": 1},
    "character": "doctor",
    "nfc_id": "sim-nfc",
    "mode": "dialogue",
    "fw": "1.6.0"
}
topic = f"development/{device_id}/request/session/{session_id}/start"
print(f"[PUB] {topic}")
print(f"     payload={json.dumps(payload)}")
result = client.publish(topic, json.dumps(payload), qos=1)
result.wait_for_publish(timeout=5)
print(f"     published rc={result.rc}")

print("\nWaiting 10s for bot_mqtt to process...")
time.sleep(10)

client.disconnect()
client.loop_stop()

# Tail newest bot_mqtt log, filter for relevant keywords
logs = sorted(glob.glob("/home/administrator/projects/chatbot/output/log/bot_mqtt-*.log"),
              key=os.path.getmtime, reverse=True)
print(f"\n[TAIL] newest log: {logs[0] if logs else 'none'}")
print("=" * 70)

KEYWORDS = ["s3://", "zeb-audio", "AWS_BUCKET", "resolve_audio",
            "Doctor Emma", session_id, "Failed to resolve",
            "Kokoro", "Synthesizing", "introduction", "audio_url",
            "build_intro_bootstrap", "intro started", "intro_completed"]

if logs:
    with open(logs[0]) as f:
        lines = f.readlines()
    # Last 200 lines, filter for keywords
    relevant = []
    for line in lines[-200:]:
        if any(kw in line for kw in KEYWORDS):
            relevant.append(line.rstrip())
    if relevant:
        for line in relevant[-60:]:
            print(line)
    else:
        print("(no relevant lines found in last 200)")
        print("--- last 20 lines for context ---")
        for line in lines[-20:]:
            print(line.rstrip())
