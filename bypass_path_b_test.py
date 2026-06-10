#!/usr/bin/env python3
"""Test bypass_vad via start_simulation() path (Path B - old single-step).
This path actually consumes _vad_bypassed flag."""
import json, urllib.request, time, sys

API = 'http://localhost:8765/api'
DID = 'path-b-test-' + str(int(time.time()))

def api(method, path, data=None):
    url = API + path
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json'}, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        return json.loads(resp.read().decode())
    except Exception as e:
        return {'error': str(e)}

# Connect device + simulate in ONE call via start_simulation()
print('=== Connect + Start Simulation (Path B, bypass_vad=True) ===')
r = api('POST', '/device/simulate', {
    'device_id': DID,
    'figurine_id': 'doctor',
    'mode': 'dialogue',
    'audio_id': '/home/administrator/projects/chatbot/tests/asr/testdata/mqtt_vad_capture_input.wav',
    'subscribe_response': True,
    'mqtt_profile': 'local',
    'bypass_vad': True,
})
print('Response:', json.dumps(r, indent=2))

sid = r.get('session_id', '')
if not sid:
    print('FAIL: no session_id'); sys.exit(1)

# Monitor
print(f'\n=== Monitor session={sid} ===')
for i in range(40):
    time.sleep(3)
    ev = api('GET', f'/device/events/{sid}')
    if isinstance(ev, list):
        for e in ev[-2:]:
            print(f'  [{i*3}s] event: {e.get("type","")}', str(e.get('data',''))[:100])
    res = api('GET', f'/device/result/{sid}')
    if isinstance(res, dict) and res.get('status') in ('completed', 'error', 'timeout'):
        r2 = res.get('result', res)
        stt = (r2.get('stt_text') or '').strip()
        tts = (r2.get('reply_text') or '').strip()
        tts_cnt = r2.get('tts_response_count', 0)
        bypassed = r2.get('vad_bypassed', '?')
        print('\n=== FINAL RESULT ===')
        print(f'  status:     {res.get("status")}')
        print(f'  vad_bypassed: {bypassed}')
        print(f'  stt_text:   "{stt[:100]}"')
        print(f'  reply_text: "{tts[:200]}"')
        print(f'  tts_chunks: {r2.get("tts_chunks")} | tts_count: {tts_cnt}')
        if stt:
            print('\n*** STT WORKED! Full pipeline verified ***')
            sys.exit(0)
        elif tts_cnt > 0:
            print('\n*** TTS works but STT still blocked (bypass not consumed at deeper level) ***')
            sys.exit(2)
        else:
            print('\n*** Pipeline broken ***')
            sys.exit(3)

print('\n*** TIMEOUT ***')
res = api('GET', f'/device/result/{sid}')
print(json.dumps(res, indent=2, ensure_ascii=False)[:2000])
sys.exit(4)
