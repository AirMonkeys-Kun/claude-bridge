#Requires -Version 5.0
<#
.SYNOPSIS
    Guard Dog — watches Guardian. Runs as Scheduled Task every 60s.
    If Guardian heartbeat is stale and no guardian process is running,
    starts a new guardian instance.

    This is the ROOT of the self-healing chain:
      Guard Dog (Scheduled Task, every 60s)
        └─→ Guardian (guardian_v3.ps1)
              ├─→ Watcher (watcher.ps1)
              ├─→ Bridge Agent (bridge_agent.py)
              └─→ Workers (worker_factory.ps1)

    Bootstrap: When ALL bridge components are down, guard-dog detects
    the missing guardian heartbeat within 60s and starts a new guardian,
    which in turn starts watcher → workers → bridge_agent.
#>

$ErrorActionPreference = "Continue"
$script:bridgeBase = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:guardianScript = Join-Path $script:bridgeBase "cluster\guardian_v3.ps1"
$script:guardianHeartbeat = Join-Path $script:bridgeBase "watcher\.guardian_heartbeat"
$script:guardianLog = Join-Path $script:bridgeBase "watcher\guard-dog.log"
$script:staleThresholdSeconds = 120  # Guardian heartbeat >120s old → investigate

$utf8 = [System.Text.UTF8Encoding]::new($false)

function GLog($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    Write-Host "$t | [GUARDDOG] $m"
    try {
        $dir = Split-Path $script:guardianLog -Parent
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
        [System.IO.File]::AppendAllText($script:guardianLog, "$t | [GUARDDOG] $m`r`n", $utf8)
    } catch {}
}

function Get-GuardianHeartbeatAge {
    <#
    Returns heartbeat age in seconds, or $null if no heartbeat file exists.
    #>
    if (-not (Test-Path $script:guardianHeartbeat)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($script:guardianHeartbeat, $utf8).Trim()
        if (-not $text) { return $null }
        $hbTime = [DateTime]::ParseExact($text, "yyyy-MM-dd HH:mm:ss.fff", $null)
        return [int]((Get-Date) - $hbTime).TotalSeconds
    } catch { return $null }
}

function Test-GuardianProcessAlive {
    <#
    Checks if ANY PowerShell process is running guardian_v3.ps1.
    Returns $true if at least one guardian process exists.
    #>
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'guardian_v3\.ps1') {
                $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                if ($proc) { return $true }
            }
        }
    } catch {}
    return $false
}

function Invoke-StartGuardian {
    <#
    Launches guardian_v3.ps1 as a detached PowerShell process.
    #>
    if (-not (Test-Path $script:guardianScript)) {
        GLog "ERROR: Guardian script not found at $script:guardianScript"
        return $false
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:guardianScript`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { throw "Process.Start returned null" }
        $null = $proc.BeginOutputReadLine()
        $null = $proc.BeginErrorReadLine()
        GLog "Launched guardian PID=$($proc.Id)"
        # Give guardian a moment to write heartbeat
        Start-Sleep -Seconds 2
        $hb = Get-GuardianHeartbeatAge
        if ($null -ne $hb) {
            GLog "Guardian heartbeat confirmed (age=${hb}s)"
        } else {
            GLog "WARNING: No heartbeat yet — guardian may still be starting"
        }
        return $true
    } catch {
        GLog "ERROR starting guardian: $_"
        return $false
    }
}

# ══════════════════════════════════
# MAIN
# ══════════════════════════════════

$hbAge = Get-GuardianHeartbeatAge

if ($null -eq $hbAge) {
    # No heartbeat file at all — check if guardian was ever started
    $procAlive = Test-GuardianProcessAlive
    if ($procAlive) {
        GLog "No heartbeat file but guardian process is running — OK (startup phase)"
        exit 0
    }
    GLog "No heartbeat file and no guardian process — STARTING GUARDIAN"
    Invoke-StartGuardian
    exit 0
}

if ($hbAge -gt $script:staleThresholdSeconds) {
    $procAlive = Test-GuardianProcessAlive
    if (-not $procAlive) {
        GLog "Heartbeat stale (${hbAge}s > ${staleThresholdSeconds}s) and no guardian process — RESTARTING"
        Invoke-StartGuardian
    } else {
        # Heartbeat stale but process alive — guardian might be stuck in a long operation
        # Don't restart yet — let it recover. If heartbeat continues aging, next cycle will escalate.
        GLog "Heartbeat stale (${hbAge}s) but guardian process alive — monitoring"
    }
    exit 0
}

# Heartbeat fresh — everything is fine. Silent exit.
GLog "Heartbeat OK (${hbAge}s) — guardian alive"
