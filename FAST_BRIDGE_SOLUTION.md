# Fast Bridge Solution — 9P Cache Elimination

## Problem
The 9P FUSE cache causes 200-600ms delay when reading `.pipe_batch_result.json` from the sandbox. This is because the file reuses the same filename, and the virtiofs daemon caches file attributes/data.

## Root Cause
- Communication channel: sandbox (Linux VM) → 9P/virtiofs → host (Windows)
- 9P FUSE caches file metadata for ~500ms for reused filenames
- `.pipe_batch_result.json` is overwritten each batch, triggering cache

## Solution: Unique Filenames
The pipe daemon writes individual result files to `watcher/r_{cmd_id}.json` for each command. Since `cmd_id` is unique per batch, the filename is always different — bypassing the 9P cache entirely.

## Performance
| Method | Latency | Cache |
|--------|---------|-------|
| Read `.pipe_batch_result.json` | 200-600ms | 9P cache on reused filename |
| `poll_result.sh <cmd_id>` | <25ms | No cache (unique filename) |

End-to-end test (batch 90): **6ms total** from master queue write to individual result read.

## How To Use

### Write batch with unique cmd_ids:
```json
{"commands": [
  {"cmd_id": "mybatch_cmd1", "command": "...", "type": "powershell"},
  {"cmd_id": "mybatch_cmd2", "command": "...", "type": "powershell"}
]}
```

### Read results fast:
```bash
# Poll for individual result (10ms intervals)
bash watcher/poll_result.sh mybatch_cmd1 5000

# Or read directly (no cache for unique names)
cat watcher/r_mybatch_cmd1.json
```

### For batch-level results:
Include a "result collector" command that writes to a unique file:
```json
{"cmd_id": "mybatch_collect", "command": "...write to _res_BATCHNUM.txt..."}
```

Then read the unique file from sandbox (no cache).

## What Doesn't Work
- **cowk-svc pipe protocol**: Server doesn't respond to non-VM clients
- **HVSock from sandbox**: Not available (gVisor sandbox)
- **TCP host↔VM**: Sandbox has loopback only, no host networking
- **Daemon console pipe**: g2 worker timeouts; protocol unclear
