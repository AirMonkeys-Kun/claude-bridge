#Requires -Version 5.0
<#
.SYNOPSIS
    Fix: register guard-dog + force V3.2 guardian to take over.
    Run this from an elevated PowerShell prompt.
#>

$ErrorActionPreference = "Continue"
$bridgeBase = $PSScriptRoot
$guardDogScript = Join-Path $bridgeBase "cluster\guard-dog.ps1"
$guardianScript = Join-Path $bridgeBase "cluster\guardian_v3.ps1"

Write-Host "=== V3.2 Fix: Guard-Dog + Guardian Restart ===" -ForegroundColor Cyan

# ── Step 1: Register BridgeGuardDog ──
Write-Host "[1/3] Registering BridgeGuardDog..." -ForegroundColor Yellow
try {
    Unregister-ScheduledTask -TaskName "BridgeGuardDog" -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$guardDogScript`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration ([TimeSpan]::FromDays(3650))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName "BridgeGuardDog" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null

    Start-ScheduledTask -TaskName "BridgeGuardDog"
    Write-Host "  BridgeGuardDog registered and started!" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $_" -ForegroundColor Red
}

# ── Step 2: Kill old V3.1 guardian process ──
Write-Host "[2/3] Killing old Guardian (V3.1)..." -ForegroundColor Yellow
try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
    $found = $false
    foreach ($p in $procs) {
        $cl = $p.CommandLine
        if ($cl -match 'guardian_v3') {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "  Killed guardian PID=$($p.ProcessId)" -ForegroundColor Green
            $found = $true
        }
    }
    if (-not $found) { Write-Host "  No guardian process found (already dead?)" -ForegroundColor Yellow }
} catch { Write-Host "  ERROR: $_" -ForegroundColor Red }

# ── Step 3: Start V3.2 guardian ──
Write-Host "[3/3] Starting V3.2 Guardian..." -ForegroundColor Yellow
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
        Write-Host "  V3.2 Guardian launched PID=$($proc.Id)" -ForegroundColor Green
    }
} catch {
    Write-Host "  ERROR starting guardian: $_" -ForegroundColor Red
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan
Write-Host "Guard-dog will check every 60s." -ForegroundColor Gray
Write-Host "Watch the log:" -ForegroundColor Gray
Write-Host "  Get-Content '$bridgeBase\watcher\guardian_v3.log' -Tail 10" -ForegroundColor Gray
