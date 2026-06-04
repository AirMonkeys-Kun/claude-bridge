#Requires -Version 5.0
<#
 Claude Bridge V21 — Watcher Restarter (self-contained)
 ────────────────────────────────────────
 Launched by watcher.ps1 before self-upgrade exit. Runs as a subprocess
 that survives the watcher's exit, waits for the old watcher PID to die,
 then starts a new watcher process.

 This eliminates the bootstrap deadlock: NO external entity (guardian,
 scheduled task, user) is needed for self-upgrades. The restarter IS the
 bootstrap entity — it inherits the watcher's Administrator token and
 lives long enough to start the replacement.

 Usage (by watcher.ps1 internally):
   powershell -NoProfile -ExecutionPolicy Bypass -File restarter.ps1 `
       -OldPID <watcher_pid> -WatcherPath "D:\...\watcher.ps1"
#>

param(
    [int]$OldPID = 0,
    [string]$WatcherPath = "",
    [string]$LogFile = ""
)

$utf8 = [System.Text.UTF8Encoding]::new($false)

function Log($m) {
    if (-not $LogFile) { return }
    try {
        $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($LogFile, "$t | [RESTARTER] $m`r`n", $utf8)
    } catch {
        # Silent — can't log, nothing more we can do
    }
}

Log "=== Restarter started ==="
Log "OldPID=$OldPID WatcherPath=$WatcherPath"

# ── Step 1: Wait for old watcher to exit ──
if ($OldPID -gt 0) {
    $retries = 0
    while ($retries -lt 120) {  # max 120s wait
        $proc = Get-Process -Id $OldPID -ErrorAction SilentlyContinue
        if (-not $proc) {
            Log "Old watcher PID=$OldPID has exited (checked ${retries}x, ~${retries}s)"
            break
        }
        # Check if process is still a watcher (not recycled PID)
        if ($proc.ProcessName -ne 'powershell') {
            Log "PID=$OldPID is no longer powershell — watcher has exited"
            break
        }
        Start-Sleep -Seconds 1
        $retries++
    }
    if ($retries -ge 120) {
        Log "WARNING: Timeout waiting for old watcher PID=$OldPID — proceeding anyway"
    }
}

# Small extra delay for file handles to release
Start-Sleep -Milliseconds 500

# ── Step 2: Verify watcher.ps1 exists ──
if (-not (Test-Path $WatcherPath)) {
    Log "ERROR: Watcher script not found at $WatcherPath — cannot restart"
    exit 1
}

# ── Step 3: Start new watcher ──
try {
    $proc = Start-Process -WindowStyle Hidden -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$WatcherPath`""
    ) -PassThru
    Log "New watcher launched: PID=$($proc.Id)"
} catch {
    Log "ERROR: Failed to start new watcher: $($_.Exception.Message)"
    exit 1
}

# ── Step 4: Brief verification — wait for heartbeat ──
$watcherDir = Split-Path -Parent $WatcherPath
$heartbeatFile = Join-Path $watcherDir ".watcher_heartbeat"
$deadline = (Get-Date).AddSeconds(10)
$lastHb = ""
$stableCount = 0

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    try {
        if (Test-Path $heartbeatFile) {
            $hb = [System.IO.File]::ReadAllText($heartbeatFile, $utf8).Trim()
            if ($hb -and $hb -ne $lastHb) {
                $lastHb = $hb
                $stableCount++
                if ($stableCount -ge 3) {
                    Log "New watcher heartbeat confirmed: $hb"
                    Log "=== Restarter exiting (success) ==="
                    exit 0
                }
            }
        }
    } catch {}
}

Log "WARNING: New watcher heartbeat not confirmed within 10s — guardian will check"
Log "=== Restarter exiting (degraded) ==="
exit 0
