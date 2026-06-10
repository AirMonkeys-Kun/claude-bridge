#!/usr/bin/env python3
"""Full-link test with bypass_vad=True to verify the complete pipeline."""
import json
import urllib.request
import time
import sys

API = 'http://localhost:8765/api'
DID = 'vad-bypass-test-' + str(int(time.time()))

def api(method, path, data=None):
    url = API + path
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json'}, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        return json.loads(resp.read().decode())
    except Exception as e:
        return {'error': str(e)}

# Step 1: Connect device
print('=== Step 1: Connect device', DID, '===')
r = api('POST', '/device/connect', {
    'device_id': DID,
    'figurine_id': 'doctor',
    'mode': 'dialogue',
    'mqtt_profile': 'local',
})
print(json.dumps(r, indent=2))
if 'error' in r and 'already' not in r.get('status', ''):
    print('FAIL: connect failed'); sys.exit(1)

# Step 2: Start session
print()
print('=== Step 2: Start session ===')
r = api('POST', '/device/start-session', {
    'device_id': DID,
    'figurine_id': 'doctor',
    'mode': 'dialogue',
})
print(json.dumps(r, indent=2)[:300])
sid = r.get('session_id', '')
if not sid:
    print('No session_id'); sys.exit(1)
print('Session:', sid)

if not r.get('intro_completed'):
    print('WARNING: intro not completed, continuing anyway')

# Step 3: Simulate audio with bypass_vad=True
print()
print('=== Step 3: Simulate audio (bypass_vad=True) ===')
r = api('POST', '/device/simulate', {
    'device_id': DID,
    'figurine_id': 'doctor',
    'mode': 'dialogue',
    'audio_id': '/home/administrator/projects/chatbot/tests/asr/testdata/mqtt_vad_capture_input.wav',
    'subscribe_response': True,
    'mqtt_profile': 'local',
    'bypass_vad': True,
})
print(json.dumps(r, indent=2)[:300])
sid = r.get('session_id', sid)
turn_status = r.get('status', '')

if turn_status == 'turn_started':
    # Step 4: Monitor for result
    print()
    print('=== Step 4: Monitor ===')
    for i in range(40):
        time.sleep(3)
        ev = api('GET', f'/device/events/{sid}')
        if isinstance(ev, list):
            for e in ev[-3:]:
                print(f'  event: {e.get("type","")} {str(e.get("data",""))[:80]}')
        res = api('GET', f'/device/result/{sid}')
        # Support both flat and nested status (flat: {status, ...}, nested: {session_id, result: {status, ...}})
        nested = res.get('result', {}) if isinstance(res, dict) else {}
        flat_status = res.get('status') if isinstance(res, dict) else None
        nested_status = nested.get('status') if isinstance(nested, dict) else None
        check_status = nested_status or flat_status
        if isinstance(res, dict) and check_status in ('completed', 'error', 'timeout'):
            print()
            payload = nested if nested else res
            print('Result:', json.dumps(res, indent=2, ensure_ascii=False)[:2000])
            stt = payload.get('stt_text', '') or ''
            tts = payload.get('reply_text', '') or ''
            tts_count = payload.get('tts_response_count', 0)
            vad_bypassed = payload.get('vad_bypassed', False)
            print()
            print('=== SUMMARY ===')
            print(f'  STT: {"OK" if stt else "EMPTY"} -> "{stt[:80]}"')
            print(f'  TTS: {"OK" if tts and tts_count > 0 else "EMPTY"} -> "{tts[:80]}"')
            print(f'  vad_bypassed: {vad_bypassed}')
            if stt and tts:
                print('  *** FULL PIPELINE PASSED ***')
            elif not stt and tts:
                print('  *** PARTIAL: VAD still blocking STT ***')
            elif stt and not tts:
                print('  *** PARTIAL: STT works but no TTS response ***')
            else:
                print('  *** FAILED: pipeline broken ***')
            sys.exit(0 if stt and tts else 2)
    else:
        res = api('GET', f'/device/result/{sid}')
        print('Final:', json.dumps(res, indent=2, ensure_ascii=False)[:2000])
        print('*** TIMEOUT: no result after 120s ***')
        sys.exit(3)
else:
    # Simulation returned immediately (start_simulation path, not send_user_turn)
    print(f'Turn status: {turn_status}')
    print()
    print('=== Step 4: Monitor ===')
    for i in range(40):
        time.sleep(3)
        res = api('GET', f'/device/result/{sid}')
        if isinstance(res, dict) and res.get('status') in ('completed', 'error', 'timeout'):
            print()
            print('Result:', json.dumps(res, indent=2, ensure_ascii=False)[:2000])
            sys.exit(0)
    else:
        res = api('GET', f'/device/result/{sid}')
        print('Final:', json.dumps(res, indent=2, ensure_ascii=False)[:2000])
        sys.exit(3)
