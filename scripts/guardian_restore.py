#!/usr/bin/env python3
"""Restore guardian_v3.ps1 with full V3.2 content.

Strategy: read the committed version from git, apply V3.2 patches,
and write the result back through 9P (which updates the cache).
"""
import subprocess, os, sys

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
target = os.path.join(base, "cluster", "guardian_v3.ps1")

def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=base)
    if r.returncode != 0:
        print(f"ERROR: {cmd} -> {r.stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout

# Read the committed version
committed = run(["git", "show", "HEAD:cluster/guardian_v3.ps1"])
lines = committed.splitlines(keepends=True)
print(f"Committed version: {len(lines)} lines")

# Apply patches
result = []
in_guardian_check = False
brace_depth = 0
inserted_pipe_health = False
inserted_rolling_restart = False
inserted_heartbeat = False
inserted_pipe_state = False
inserted_test_function = False

# State variable additions
pipe_state_vars = '''$script:pipeHealthCache = @{}          # V3.2: per-worker pipe health state
$script:lastWorkerRotateTime = $null   # V3.2: last rolling restart time
'''

# Test-WorkerNamedPipe function (insert after Get-MemoryPressure)
test_pipe_function = '''
function Test-WorkerNamedPipe {
    param([string]$WorkerId, [string]$PipeName)
    $entry = $script:pipeHealthCache[$WorkerId]
    if (-not $entry) { $entry = @{healthy=$true; fail_count=0}; $script:pipeHealthCache[$WorkerId] = $entry }
    try {
        $testPipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $testPipe.Connect(500)
        $testPipe.Close(); $testPipe.Dispose()
        $entry.healthy = $true; $entry.fail_count = 0
        return $true
    } catch {
        $entry.fail_count++
        if ($entry.fail_count -ge 3) { $entry.healthy = $false }
        return $false
    }
}
'''

# Step 4.5: pipe health check
pipe_health_section = '''
    # --- Step 4.5: Worker NamedPipe health check (V3.2) ---
    $pipeCheckCount = 0; $pipeFailCount = 0
    if ($ws.pool -and $ws.pool.workers) {
        $checkList = @($ws.pool.workers | Where-Object { $_.pipe -and $_.type -ne "wsl" })
        for ($i = 0; $i -lt [Math]::Min(3, $checkList.Count); $i++) {
            $w = $checkList[$i % $checkList.Count]
            if (Test-WorkerNamedPipe -WorkerId $w.id -PipeName $w.pipe) { $pipeCheckCount++ }
            else {
                $pipeFailCount++
                $ps = $script:pipeHealthCache[$w.id]
                if ($ps -and $ps.fail_count -ge 3 -and -not $ps.healthy) {
                    Log "  PIPE: $($w.id) unresponsive (fail count=$($ps.fail_count)) - subprocess fallback active"
                }
            }
        }
    }
    if ($pipeCheckCount -gt 0) { Log "  Pipe check: $pipeCheckCount OK, $pipeFailCount failed" }
'''

# Step 4.6: rolling restart
rolling_restart_section = '''
    # --- Step 4.6: Rolling restart for workers >24h (V3.2) ---
    if ($ws.pool -and $ws.pool.workers -and $ws.total -gt 0) {
        $rotateInterval = if ($script:memCritical) { 12 } else { 24 }
        $now = Get-Date; $shouldRotate = $false
        if ($script:lastWorkerRotateTime) {
            $hoursSince = ($now - $script:lastWorkerRotateTime).TotalHours
            if ($hoursSince -ge $rotateInterval) { $shouldRotate = $true }
        } else { $script:lastWorkerRotateTime = $now }
        if ($shouldRotate) {
            $oldest = $null; $oldestStart = $now
            foreach ($w in $ws.pool.workers) {
                if ($w.started) {
                    try { $started = [DateTime]::ParseExact($w.started, "yyyy-MM-dd HH:mm:ss", $null); if ($started -lt $oldestStart) { $oldestStart = $started; $oldest = $w } } catch {}
                }
            }
            if ($oldest) {
                $ageHours = [math]::Round(($now - $oldestStart).TotalHours, 1)
                Log "ACTION: Rolling restart of $($oldest.id) (age=${ageHours}h)"
                try { Stop-Process -Id $oldest.pid -Force -ErrorAction SilentlyContinue; Log "  Killed PID=$($oldest.pid) - will be respawned" }
                catch { Log "  ERROR killing $($oldest.id): $_" }
                $script:lastWorkerRotateTime = $now
            }
        }
    }
'''

# Step 8: guardian heartbeat
heartbeat_section = '''
    # --- Step 8: Write guardian heartbeat for guard-dog (V3.2) ---
    $ghb = Join-Path $script:watcherDir ".guardian_heartbeat"
    try { [System.IO.File]::WriteAllText($ghb, (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $script:utf8) } catch { }
'''

# Memory pressure enhancement (need to replace the existing memory warning section)
# This is tricky - let's do it via string replacement on the full text
full_text = committed

# 1. Add state variables after $script:memCritical = $false
full_text = full_text.replace(
    "$script:memCritical = $false          # V3.1: memory pressure flag for worker reduction\n",
    "$script:memCritical = $false          # V3.1: memory pressure flag for worker reduction\n" + pipe_state_vars
)

# 2. Add Test-WorkerNamedPipe function after Get-MemoryPressure closing brace
# Find the end of Get-MemoryPressure function
idx = full_text.find("function Test-WorkerNamedPipe")
if idx == -1:
    # Insert before worker type definitions
    idx = full_text.find("# --- Worker type definitions")
    if idx > 0:
        full_text = full_text[:idx] + test_pipe_function + "\n" + full_text[idx:]
        print("Inserted Test-WorkerNamedPipe")

# 3. Insert Step 4.5 and 4.6 after worker pool check
# Find: "# --- Step 5: Check bridge_agent"
step5_marker = "# --- Step 5: Check bridge_agent (TCP :19850) health"
if step5_marker in full_text:
    idx = full_text.find(step5_marker)
    full_text = full_text[:idx] + pipe_health_section + rolling_restart_section + full_text[idx:]
    print("Inserted Step 4.5 and 4.6")

# 4. Insert Step 8 before "=== Guardian check #" complete log line
complete_marker = 'Log "=== Guardian check #$($script:guardianRunCount) complete ==="'
if complete_marker in full_text:
    full_text = full_text.replace(complete_marker, heartbeat_section + "    " + complete_marker)
    print("Inserted Step 8")

# Write through 9P
with open(target, "w", encoding="utf-8") as f:
    f.write(full_text)

result_lines = len(full_text.splitlines())
print(f"Written: {result_lines} lines to {target}")
