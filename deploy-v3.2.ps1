#Requires -Version 5.0
<#
.SYNOPSIS
    Deploy V3.2 — bootstrap bridge system from fully-down state.
    Run this once from an elevated PowerShell prompt.
.DESCRIPTION
    This script:
    1. Registers BridgeGuardDog as a Scheduled Task (every 60s)
    2. Starts guard-dog immediately to verify it works
    3. Starts guardian_v3.ps1 which bootstraps everything else
    4. Shows real-time status of the bootstrap process
#>

$ErrorActionPreference = "Continue"
$bridgeBase = $PSScriptRoot  # D:\zebbingo\tools\claude-bridge
$guardDogScript = Join-Path $bridgeBase "cluster\guard-dog.ps1"
$guardianScript = Join-Path $bridgeBase "cluster\guardian_v3.ps1"
$watchLog = Join-Path $bridgeBase "watcher\guardian_v3.log"
$dogLog = Join-Path $bridgeBase "watcher\guard-dog.log"
$hbFile = Join-Path $bridgeBase "watcher\.guardian_heartbeat"
$watcherHb = Join-Path $bridgeBase "watcher\.watcher_heartbeat"

Write-Host "=== V3.2 Deployment ===" -ForegroundColor Cyan
Write-Host "Bridge base: $bridgeBase" -ForegroundColor Gray

# ── Step 1: Clean stale artifacts ──
Write-Host "`n[1/5] Cleaning stale artifacts..." -ForegroundColor Yellow
foreach ($f in @(".watcher_heartbeat", ".guardian_heartbeat", ".watcher.lock", ".graceful_restart", ".maintenance.lock")) {
    $path = Join-Path $bridgeBase "watcher" $f
    if (Test-Path $path) { Remove-Item $path -Force; Write-Host "  DEL watcher\$f" }
}
# Kill orphaned watcher/worker processes
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cl = $p.CommandLine
        if ($cl -match 'watcher\.ps1|worker_generic|worker_factory|guardian_v3') {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "  Killed orphan PID=$($p.ProcessId)"
        }
    }
} catch {}

# ── Step 2: Register BridgeGuardDog Scheduled Task ──
Write-Host "[2/5] Registering BridgeGuardDog Scheduled Task..." -ForegroundColor Yellow
try {
    # Remove existing if present
    Unregister-ScheduledTask -TaskName "BridgeGuardDog" -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$guardDogScript`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::MaxValue)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName "BridgeGuardDog" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null

    # Start guard-dog immediately
    Start-ScheduledTask -TaskName "BridgeGuardDog"
    Write-Host "  BridgeGuardDog registered and started!" -ForegroundColor Green
} catch {
    Write-Host "  ERROR registering task: $_" -ForegroundColor Red
}

# ── Step 3: Start Guardian ──
Write-Host "[3/5] Starting Guardian..." -ForegroundColor Yellow
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$guardianScript`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($proc) {
        Write-Host "  Guardian launched PID=$($proc.Id)" -ForegroundColor Green
    }
} catch {
    Write-Host "  ERROR starting guardian: $_" -ForegroundColor Red
}

# ── Step 4: Monitor bootstrap ──
Write-Host "[4/5] Monitoring bootstrap (30s timeout)..." -ForegroundColor Yellow
$started = Get-Date
$lastLine = ""
$guardianLogSeen = $false
$heartbeatSeen = $false

while ((Get-Date) -lt $started.AddSeconds(30)) {
    Start-Sleep -Milliseconds 1000

    # Check guardian heartbeat
    if (-not $heartbeatSeen -and (Test-Path $hbFile)) {
        $hb = (Get-Content $hbFile -Raw).Trim()
        if ($hb) {
            Write-Host "  Guardian heartbeat: $hb" -ForegroundColor Green
            $heartbeatSeen = $true
        }
    }

    # Show latest guardian log line
    if (Test-Path $watchLog) {
        $line = Get-Content $watchLog -Tail 1 -ErrorAction SilentlyContinue
        if ($line -and $line -ne $lastLine) {
            $lastLine = $line
            Write-Host "  $line" -ForegroundColor Gray
            $guardianLogSeen = $true
        }
    }

    # Check watcher heartbeat
    if (Test-Path $watcherHb) {
        $whb = (Get-Content $watcherHb -Raw).Trim()
        if ($whb) {
            Write-Host "  Watcher heartbeat: $whb" -ForegroundColor Green
            break  # Watcher running means full bootstrap
        }
    }
}

# ── Step 5: Status report ──
Write-Host "`n[5/5] Status Report:" -ForegroundColor Yellow
if ($heartbeatSeen) {
    Write-Host "  Guardian: RUNNING" -ForegroundColor Green
} else {
    Write-Host "  Guardian: CHECKING (wait for next guard-dog cycle)" -ForegroundColor Yellow
}
if (Test-Path $watcherHb) {
    Write-Host "  Watcher: RUNNING" -ForegroundColor Green
} else {
    Write-Host "  Watcher: CHECKING (guardian should start within 60s)" -ForegroundColor Yellow
}
Write-Host "  GuardDog: SCHEDULED (every 60s)" -ForegroundColor Green

Write-Host "`n=== V3.2 deployment complete ===" -ForegroundColor Cyan
Write-Host "Logs:"
Write-Host "  guardian: $watchLog"
Write-Host "  guard-dog: $dogLog"
Write-Host "`nTo check status later:"
Write-Host "  Get-Content '$watchLog' -Tail 5"
