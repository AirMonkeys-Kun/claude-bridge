#Requires -Version 5.0
<#
queue-monitor.ps1 — hybrid queue watching (V18 modular bridge)
  Primary:   EventWaitHandle (zero-sleep, kernel-signaled, ~0ms wake latency)
  Fallback:  FileSystemWatcher.WaitForChanged() (in-process, 50ms timeout)
  Strategy:  Try EventWaitHandle first. If it crashes or isn't available
             (known issue in PS 5.1 non-interactive sessions), fall back
             to FSW automatically.
  Exports:   Start-QueueMonitor, Wait-QueueChange, Read-Queue
#>

# ── Dependencies ──────────────────────────────────────────────────────
. "$PSScriptRoot\bridge-core.ps1"

# ── State ─────────────────────────────────────────────────────────────
$script:monitorMode = ""       # "ewh" or "fsw"
$script:queueEvent = $null     # EventWaitHandle object
$script:queueWatcher = $null   # FileSystemWatcher object

# ── EventWaitHandle name ──────────────────────────────────────────────
$script:ewhName = "Local\Bridge_Queue_V18"

# ── Initialize queue monitor ──────────────────────────────────────────
function Start-QueueMonitor {
    # Try EventWaitHandle first (scheduler pattern — zero-sleep)
    try {
        $script:queueEvent = New-Object System.Threading.EventWaitHandle(
            $false,
            [System.Threading.EventResetMode]::AutoReset,
            $script:ewhName
        )
        $script:monitorMode = "ewh"
        Log "Queue monitor: EventWaitHandle ($($script:ewhName)) — zero-sleep mode"
        return $true
    } catch {
        Log "Queue monitor: EventWaitHandle unavailable ($_) — falling back to FileSystemWatcher"
    }

    # Fallback to FileSystemWatcher (watcher V15+ pattern — stable, 50ms timeout)
    try {
        $script:queueWatcher = New-Object System.IO.FileSystemWatcher
        $script:queueWatcher.Path = $script:watcherDir
        $script:queueWatcher.Filter = "queue.txt"
        $script:queueWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
        $script:monitorMode = "fsw"
        Log "Queue monitor: FileSystemWatcher — 50ms timeout mode"
        return $true
    } catch {
        Log "FATAL: Queue monitor initialization failed: $_"
        return $false
    }
}

# ── Wait for queue change ─────────────────────────────────────────────
function Wait-QueueChange {
    param([int]$TimeoutMs = 500)

    if ($script:monitorMode -eq "ewh") {
        # Zero-sleep: blocks until Set() is called, or timeout
        try {
            $script:queueEvent.WaitOne($TimeoutMs) | Out-Null
            return
        } catch {
            Log "Queue monitor: EventWaitHandle crashed ($_) — switching to FSW"
            $script:monitorMode = "fsw"
            try { $script:queueEvent.Dispose() } catch {}
            $script:queueWatcher = New-Object System.IO.FileSystemWatcher
            $script:queueWatcher.Path = $script:watcherDir
            $script:queueWatcher.Filter = "queue.txt"
            $script:queueWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
        }
    }

    if ($script:monitorMode -eq "fsw") {
        try {
            $script:queueWatcher.WaitForChanged(
                [System.IO.WatcherChangeTypes]::Changed,
                $TimeoutMs
            ) | Out-Null
        } catch {
            # FSW can throw if the directory is deleted; sleep and retry next loop
            Start-Sleep -Milliseconds ($TimeoutMs)
        }
    }
}

# ── Signal queue event (called by writers via named event) ────────────
function Signal-QueueChange {
    try {
        # Open the existing event (created by Start-QueueMonitor) and signal it
        $evt = [System.Threading.EventWaitHandle]::OpenExisting($script:ewhName)
        if ($evt) { $evt.Set() | Out-Null; $evt.Dispose() }
    } catch {}
}

# ── Read current queue state ──────────────────────────────────────────
function Read-Queue {
    return Read-JsonFile $script:queueFile
}

# ── Set queue to idle ─────────────────────────────────────────────────
function Reset-Queue {
    Write-File $script:queueFile $script:idleWatcherQueue
}

# ── Signal writer that result is ready ────────────────────────────────
# (in V15+, writers just poll r_{cid}.json — no event needed)
# This is kept for future use if we add a result event
function Signal-ResultReady { param([string]$CmdId)
    # Reserved for future result event
}

Log "queue-monitor loaded: mode=$($script:monitorMode)"
