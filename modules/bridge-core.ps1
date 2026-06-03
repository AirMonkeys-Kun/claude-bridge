#Requires -Version 5.0
<#
bridge-core.ps1 — shared utilities and path configuration
  Part of V18 modular bridge: dot-source this first in any module or bridge.ps1.
  Provides: paths, UTF8, Log (with fallback), Write-Text, Read-Json.
#>

# ── Paths ────────────────────────────────────────────────────────────
# bridgeRoot may already be set by the caller (bridge.ps1).
# If not, derive it from this module's location.
if (-not $script:bridgeRoot) {
    $script:bridgeRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$script:modulesDir  = Join-Path $script:bridgeRoot "modules"
$script:clusterDir  = Join-Path $script:bridgeRoot "cluster"
$script:watcherDir  = Join-Path $script:bridgeRoot "watcher"

# Canonical queue — keeps backward compat with all existing clients
$script:queueFile   = Join-Path $script:watcherDir "queue.txt"
$script:resultDir   = $script:watcherDir  # results written here (r_{cid}.json)
$script:logFile     = Join-Path $script:bridgeRoot "bridge.log"
$script:heartbeatFile = Join-Path $script:bridgeRoot ".bridge_heartbeat"
$script:lockFile    = Join-Path $script:bridgeRoot ".bridge.lock"
$script:rulesFile   = Join-Path $script:watcherDir "bridge_rules.json"
$script:errorHistoryFile = Join-Path $script:watcherDir "error_history.json"

# ── Encoding ──────────────────────────────────────────────────────────
$script:utf8 = [System.Text.UTF8Encoding]::new($false)

# ── Idle queue template (watcher protocol) ───────────────────────────
$script:idleWatcherQueue  = '{"state":"idle","cmd_id":"","command":"","type":""}'
$script:idleBatchQueue    = '{"v":3,"state":"idle","c":[],"r":{}}'

# ── Log with fallback ─────────────────────────────────────────────────
function Write-BridgeLog { param([string]$Message)
    try {
        $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($script:logFile, "$t | $Message`r`n", $script:utf8)
    } catch {
        try {
            $fallbackPath = Join-Path $script:bridgeRoot ".bridge_fallback.log"
            $errMsg = $_.Exception.Message
            [System.IO.File]::AppendAllText($fallbackPath, "$t | LOG_FAIL: $errMsg`r`n", $script:utf8)
            [System.IO.File]::AppendAllText($fallbackPath, "$t | ORIGINAL: $Message`r`n", $script:utf8)
        } catch {}
    }
}

# Alias for brevity
Set-Alias -Name Log -Value Write-BridgeLog -Scope Script

# ── Atomic file write ─────────────────────────────────────────────────
function Write-File { param([string]$Path, [string]$Content)
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            [System.IO.File]::WriteAllText($Path, $Content, $script:utf8)
            return
        } catch {
            if ($i -eq $retries - 1) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

# ── JSON file reader ──────────────────────────────────────────────────
function Read-JsonFile { param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            $text = [System.IO.File]::ReadAllText($Path, $script:utf8)
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        } catch {
            if ($i -eq $retries - 1) { return $null }
            Start-Sleep -Milliseconds 50
        }
    }
}

# ── Heartbeat writer ──────────────────────────────────────────────────
function Write-Heartbeat {
    try {
        [System.IO.File]::WriteAllText(
            $script:heartbeatFile,
            (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"),
            $script:utf8
        )
    } catch {}
}

# ── PID lock ──────────────────────────────────────────────────────────
function Acquire-Lock {
    if (Test-Path $script:lockFile) {
        try {
            $oldPid = [int]([System.IO.File]::ReadAllText($script:lockFile, $script:utf8).Trim())
            $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($oldProc -and $oldProc.ProcessName -match "powershell") {
                return $false  # Another instance is running
            }
        } catch {}
    }
    try {
        [System.IO.File]::WriteAllText($script:lockFile, [string]$PID, $script:utf8)
        Log "Lock acquired: PID=$PID"
        return $true
    } catch {
        Log "WARNING: could not write lock file: $_"
        return $true  # proceed anyway
    }
}

function Release-Lock {
    try { Remove-Item $script:lockFile -Force -ErrorAction SilentlyContinue } catch {}
}

Log "bridge-core loaded: bridgeRoot=$($script:bridgeRoot)"
