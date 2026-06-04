# Vsock Doorbell — Status: BLOCKED (kernel lacks vsock support)

**Updated: 2026-06-04 04:28 UTC**

## Verdict

**The Cowork VM kernel (6.8.0-106-generic, Ubuntu 22.04.1) does NOT support vsock.** No CONFIG_VSOCKETS, no CONFIG_HYPERV_VSOCKETS, no vsock kernel modules in initrd. The Hyper-V socket doorbell approach is fundamentally impossible with the current kernel without replacing or augmenting it.

## Evidence

- `vmlinuz` (15MB EFI-stub kernel, extracted gzip offset 10,158,314): zero "vsock" or "hv_sock" strings
- `initrd` (177MB cpio newc, decompressed): 0 vsock refs, 0 hv_sock refs, 0 CONFIG_VSOCK refs, 0 CONFIG_HYPERV refs
- WSL2 reference: same host has `/dev/vsock`, `CONFIG_HYPERV_VSOCKETS=y`, and vsock kernel modules — proving the Hyper-V host CAN support vsock, just not the Cowork VM's kernel
- Host-side: AF_HYPERV socket creation succeeds with .NET Socket class, but connect returns WSAEADDRNOTAVAIL (10049) because guest has no `/dev/vsock`

## What was deployed (all done)

### Guest-side (VM rootfs)
- `vsock_doorbell_daemon.py` — Python daemon bridging vsock port 9999 ↔ Unix socket `/tmp/bridge-doorbell.sock`
- Deployed at `/usr/local/bin/vsock_doorbell_daemon.py` (V14, verified)
- systemd service `/etc/systemd/system/vsock-doorbell.service` — enabled, auto-starts
- **Cannot function**: daemon tries to bind AF_VSOCK but `/dev/vsock` doesn't exist

### Host-side (Windows)
- `send_vsock_doorbell.ps1` — C# P/Invoke Hyper-V socket sender
- `doorbell_send_wrapper.ps1` — Bridge integration with graceful fallback
- VM GUIDs in HCS registry: `cowork-vm-0646589c` (named) and `8ED8405F-EF07-4D2D-924B-6BCBC4CFDB51` (GUID, likely WSL2)
- **Blocked**: connect() fails with WSAEADDRNOTAVAIL (10049)

### Sandbox-side
- `bridge_doorbell_listener.py` — connects to `/tmp/bridge-doorbell.sock`, does os.stat() on queue files to bust FUSE cache
- **Blocked**: daemon can't create the Unix socket

## Architecture

```
Host (Windows)                              Guest (Linux VM)
─────────────────────────────────────────────────────────────────
doorbell_send_wrapper.ps1                   vsock_doorbell_daemon.py (BLOCKED)
  ├── Write .pipe_master_queue.json           ├── AF_VSOCK(9999) ← needs /dev/vsock ✗
  └── send_vsock_doorbell.ps1                 └── Unix socket → bridge_doorbell_listener.py
       └── AF_HYPERV connect → VMBus →            └── stat(queue files) → bust FUSE cache
           BLOCKED: guest no vsock support

Pipe Daemon (host)                          Worker Pool (host)
  ├── FSW watches .pipe_master_queue.json      ├── g2 (PID=23324): pipe timeout on first cmd ⚠
  ├── Dispatches via Named Pipes               ├── g3-g6: working correctly ✓
  └── Results → .pipe_batch_result.json        └── g1: removed from pool
```

## Known Issues (operational)

- **g2 pipe timeout**: First command dispatched in every batch to g2 times out (5s). g3-g6 work fine. Workaround: always dispatch 6 commands.
- **bash workspace unavailable**: `mcp__workspace__bash` returns "VM service not running" — all work goes through bridge queue

## Paths Forward

### Option A: Custom Kernel (high risk, ideal result)
Replace `vmlinuz` with a custom build that has `CONFIG_HYPERV_VSOCKETS=y`.
- Must match Ubuntu 22.04 ABI for initrd module compatibility
- ~1ms doorbell latency if successful

### Option B: 9P Cache Tuning (medium risk)
Reduce FUSE `entry_timeout`/`attr_timeout` on the 9P mount in the sandbox.
- Controlled by cowk-svc.exe mount configuration
- Would eliminate doorbell need — FSW would see changes immediately

### Option C: TCP Alternative (medium effort)
Set up TCP communication between host and guest via virtual NIC.

### Option D: Accept Baseline (no effort)
200-600ms 9P FUSE delay is the current baseline.
