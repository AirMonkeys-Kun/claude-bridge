"""Test S3 intro fix — publish session_start, wait longer, dump full bot_mqtt tail (unfiltered)."""
import os, json, time, glob, sys
from dotenv import load_dotenv
load_dotenv("/home/administrator/projects/chatbot/.env")
import paho.mqtt.client as mqtt
try:
    from paho.mqtt.enums import CallbackAPIVersion
    client = mqtt.Client(callback_api_version=CallbackAPIVersion.VERSION2)
except Exception:
    client = mqtt.Client()

mqtt_host = os.getenv("MQTT_HOST", "localhost")
mqtt_port = int(os.getenv("MQTT_PORT", "1883"))
print(f"[MQTT] connecting to {mqtt_host}:{mqtt_port}")

client.connect(mqtt_host, mqtt_port, 60)
client.loop_start()
# Wait briefly to ensure connected
time.sleep(1)

# Publish with unique session_id and timestamped to find in logs easily
ts_marker = f"s3test-{int(time.time())}"
device_id = "sim-test-s3fix"
session_id = ts_marker
payload = {
    "turn_proto": 1,
    "audio": {"codec": "opus", "sr": 16000, "channels": 1},
    "character": "doctor",
    "nfc_id": "sim-nfc",
    "mode": "dialogue",
    "fw": "1.6.0"
}
topic = f"development/{device_id}/request/session/{session_id}/start"
print(f"\n[PUB] topic={topic}")
print(f"     payload={json.dumps(payload)}")
print(f"     marker={ts_marker}")

result = client.publish(topic, json.dumps(payload), qos=1)
result.wait_for_publish(timeout=5)
print(f"     published rc={result.rc}")

print("\nWaiting 20s for bot_mqtt to process...")
time.sleep(20)

client.disconnect()
client.loop_stop()

# Dump last 80 lines of newest bot_mqtt log UNFILTERED
logs = sorted(glob.glob("/home/administrator/projects/chatbot/output/log/bot_mqtt-*.log"),
              key=os.path.getmtime, reverse=True)
print(f"\n[TAIL] newest log file: {logs[0] if logs else 'none'}")
print("=" * 70)
if logs:
    with open(logs[0]) as f:
        all_lines = f.readlines()
    print(f"(total lines: {len(all_lines)})")
    print("--- LAST 80 LINES (unfiltered) ---")
    for line in all_lines[-80:]:
        print(line.rstrip())
