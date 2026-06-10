"""Analyze test WAV file - energy analysis (no torch dependency needed)."""
import sys, os, struct, json
import numpy as np

wav_path = "D:\\zebbingo\\projects\\chatbot-main-sgtest\\tests\\asr\\testdata\\mqtt_vad_capture_input.wav"
with open(wav_path, "rb") as f:
    raw = f.read()

# Parse WAV - scan for fmt and data chunks
pos = 12
audio_data = None
sample_rate, num_channels, bits_per_sample = 16000, 1, 16

while pos + 8 < len(raw):
    chunk_id = raw[pos:pos+4]
    chunk_size = struct.unpack('<I', raw[pos+4:pos+8])[0]
    if chunk_id == b'fmt ':
        audio_format = struct.unpack('<H', raw[pos+8:pos+10])[0]
        num_channels = struct.unpack('<H', raw[pos+10:pos+12])[0]
        sample_rate = struct.unpack('<I', raw[pos+12:pos+16])[0]
        bits_per_sample = struct.unpack('<H', raw[pos+22:pos+24])[0]
    elif chunk_id == b'data':
        audio_data = raw[pos+8:pos+8+chunk_size]
        break
    pos += 8 + chunk_size

duration_secs = len(audio_data) / (sample_rate * num_channels * (bits_per_sample // 8))
print(f"WAV: {num_channels}ch {sample_rate}Hz {bits_per_sample}bit, {duration_secs:.2f}s")
print(f"Data bytes: {len(audio_data)}")

# Convert to float samples
if bits_per_sample == 16:
    samples = np.frombuffer(audio_data, dtype=np.int16).astype(np.float32) / 32768.0
else:
    samples = np.frombuffer(audio_data, dtype=np.int32).astype(np.float32) / 2147483648.0
if num_channels > 1:
    samples = samples.reshape(-1, num_channels)[:, 0]

print(f"\nOverall: RMS={np.sqrt(np.mean(samples**2)):.6f}")
print(f"Peak: max={samples.max():.4f} min={samples.min():.4f}")
print(f"Non-silent (|x|>0.005): {(np.abs(samples)>0.005).sum()}/{len(samples)} samples")

# --- VAD-mimicking analysis ---
# SileroVAD uses 30ms windows with 50% overlap, outputting a prob per window
frame_ms = 30
hop_ms = 10  # 10ms hop = 33% overlap (close to typical VAD)
frame_n = int(sample_rate * frame_ms / 1000)
hop_n = int(sample_rate * hop_ms / 1000)

vad_frames = []
for start in range(0, len(samples) - frame_n + 1, hop_n):
    frame = samples[start:start+frame_n]
    # Energy-based proxy for VAD confidence
    rms = np.sqrt(np.mean(frame**2))
    peak = np.abs(frame).max()
    # Estimate VAD confidence using sigmoid mapping of SNR
    noise_floor = max(1e-6, np.median(np.abs(samples[:max(1600, int(0.1*sample_rate))])))  # first 0.1s as noise ref
    snr = rms / max(1e-6, noise_floor)
    # Rough confidence mapping: SNR 1->0.1, SNR 10->0.5, SNR 100->0.9
    vad_conf = 1.0 / (1.0 + np.exp(-0.5 * (20*np.log10(max(snr, 1e-6)) - 10)))
    vad_frames.append({
        'time': start / sample_rate,
        'rms': rms,
        'peak': peak,
        'snr_db': 20 * np.log10(max(snr, 1e-6)),
        'vad_est': float(vad_conf)
    })

print(f"\nTotal VAD frames: {len(vad_frames)}")
print(f"VAD confidence distribution:")
confs = [f['vad_est'] for f in vad_frames]
for thresh in [0.05, 0.1, 0.2, 0.3, 0.5, 0.8]:
    above = sum(1 for c in confs if c > thresh)
    print(f"  > {thresh:.2f}: {above:5d} frames ({above/len(confs)*100:5.1f}%)")

# Print a compact timeline of first 200 frames
print(f"\nVAD timeline (first {min(200, len(vad_frames))} frames, '.'=silence 'm'=mid 'V'=voice):")
line_chars = []
for i, f in enumerate(vad_frames[:200]):
    if f['vad_est'] < 0.2:
        line_chars.append('.')
    elif f['vad_est'] > 0.8:
        line_chars.append('V')
    else:
        line_chars.append('m')

# Print 40 chars per line (each char = 10ms, so 40 = 0.4s)
for row in range(0, len(line_chars), 40):
    chunk = line_chars[row:row+40]
    t_start = row * hop_ms / 1000
    t_end = (row + len(chunk)) * hop_ms / 1000
    print(f"  [{t_start:5.2f}-{t_end:5.2f}s] {''.join(chunk)}")

# Print specific detailed frames - look at frames around VAD transitions
print(f"\nDetailed pass: frames with voice-quality energy")
voice_frames = [f for f in vad_frames if f['rms'] > 0.02]
print(f"Frames with RMS > 0.02: {len(voice_frames)}")
if voice_frames:
    print(f"First voice frame at t={voice_frames[0]['time']:.3f}s, last at t={voice_frames[-1]['time']:.3f}s")

mid_frames = [f for f in vad_frames if 0.005 < f['rms'] <= 0.02]
print(f"Frames with 0.005 < RMS <= 0.02: {len(mid_frames)}")
if mid_frames:
    print(f"First mid frame at t={mid_frames[0]['time']:.3f}s, last at t={mid_frames[-1]['time']:.3f}s")

# Key question: does the audio have any voice-quality content?
if voice_frames:
    print(f"\n### CONCLUSION: Audio HAS voice-quality segments (RMS > 0.02)")
    print(f"### Pipecat default VAD (confidence=0.8) should detect speech")
    max_conf = max(f['vad_est'] for f in vad_frames)
    print(f"### Estimated max VAD confidence: {max_conf:.3f}")
    print(f"### Frames with VAD > 0.8: {sum(1 for f in vad_frames if f['vad_est'] > 0.8)}/{len(vad_frames)} ({sum(1 for f in vad_frames if f['vad_est'] > 0.8)/len(vad_frames)*100:.1f}%)")
else:
    print(f"\n### CONCLUSION: Audio seems to have NO clear voice segments")
    print(f"### Check if this is silence/noise-only audio")

# --- Specific test: does Snakers4 VAD help or is it a different issue? ---
# Snakers4: confidence >= 0.8 -> voice, <= 0.2 -> silence, middle -> keep state
# If audio has no frames with VAD_est > 0.8, even Snakers4 won't trigger
print(f"\n--- Snakers4 simulation ---")
print(f"  _low_confidence = 0.2 (silence threshold)")
print(f"  _params.confidence = 0.8 (voice threshold)")
print(f"  Middle range (0.2-0.8): keep previous state")
print(f"  Frame window threshold = 3 (need 3+ voice frames to switch to voice)")
print(f"  Stop seconds = 0.8 (silence timeout after last voice)")

for low_conf in [0.2, 0.1, 0.05]:
    state = False  # start in silence
    window = []
    window_threshold = 3
    state_changes = []
    last_voice_frame = -1
    voice_start = -1

    for i, f in enumerate(vad_frames):
        c = f['vad_est']
        window.append(1 if c > 0.8 else 0)
        if len(window) > window_threshold:
            window.pop(0)

        if c >= 0.8:
            last_voice_frame = i

        new_state = state
        if sum(window) >= window_threshold and c > 0.8:
            new_state = True
        elif c <= low_conf:
            new_state = False

        if new_state != state:
            state = new_state
            state_changes.append((i, f['time'], 'VOICE' if state else 'SILENCE'))

        # Silence timeout
        if state and (i - last_voice_frame) * hop_ms / 1000 > 0.8:
            state = False
            state_changes.append((i, f['time'], 'SILENCE (timeout)'))

    voice_pct = sum(1 for f in vad_frames if f['vad_est'] > 0.8) / len(vad_frames) * 100 if vad_frames else 0
    print(f"\nWith low_confidence={low_conf}:")
    print(f"  Frames > 0.8: {sum(1 for f in vad_frames if f['vad_est'] > 0.8)}/{len(vad_frames)} ({voice_pct:.1f}%)")
    if state_changes:
        for idx, t, label in state_changes[:10]:
            print(f"  {label} at t={t:.3f}s (frame {idx})")
        if len(state_changes) > 10:
            print(f"  ... and {len(state_changes)-10} more state changes")
    else:
        print(f"  No state changes detected")

print("\nDone")
