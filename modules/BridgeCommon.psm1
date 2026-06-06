<#
.SYNOPSIS
    BridgeCommon — shared utility functions for the Claude Bridge system.
.DESCRIPTION
    Eliminates code duplication across watcher.ps1, worker.ps1, worker_generic.ps1,
    worker_template.ps1, and guardian_v3.ps1 by providing:
    - Safe file I/O (retry-based read/write)
    - Logging
    - Heartbeat management
    - PID lock files
    - Queue JSON helpers
#>

# ── UTF-8 No BOM encoding (singleton) ──
$Script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ── Constants ──
$Script:IdleQueueJson = '{"state":"idle","cmd_id":"","command":"","type":""}'
$Script:MaxFileRetries = 3
$Script:FileRetryDelayMs = 50

# ══════════════════════════════════════════════════════════════════
# File I/O helpers
# ══════════════════════════════════════════════════════════════════

function Write-SafeFile {
    <#
    .SYNOPSIS
        Write text to a file with retry on failure, using atomic temp+rename.
    .DESCRIPTION
        DEFECT FIXED (2026-06-06): Previous version used direct WriteAllText() which
        causes 9P/virtiofs cache issues — the Linux VM can see a partially-written file
        via the 9P protocol. When bridge_wait.py polls for r_{cmd_id}.json result files,
        it may find the file exists but contains incomplete JSON, leading to parse errors
        or stale data. The 50ms "flush buffer" sleep in bridge_wait.py was a workaround
        but not a root fix.

        Root cause: WriteAllText opens the file, writes content, then closes. On 9P/virtiofs
        the file metadata (existence, size) is updated before the content is fully flushed
        to the host filesystem. A concurrent reader on the VM side sees the file "exists"
        but gets partial or cached-stale content.

        Fix: Write to a temp file first ($Path.tmp), then atomically Move-Item to the
        final path. On NTFS, Move-Item is atomic for same-volume renames, so the reader
        on the VM side either sees no file (old state) or a complete file (new state).
        There is no intermediate "partial" state visible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $tmpPath = "$Path.tmp"
    for ($i = 0; $i -lt $Script:MaxFileRetries; $i++) {
        try {
            # Phase 1: Write to temp file
            [System.IO.File]::WriteAllText($tmpPath, $Content, $Script:Utf8NoBom)
            # Phase 2: Atomic rename to final path (same-volume Move is atomic on NTFS)
            Move-Item -LiteralPath $tmpPath -Destination $Path -Force
            return
        } catch {
            # Clean up temp file on failure
            try { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue } catch {}
            if ($i -eq $Script:MaxFileRetries - 1) { throw }
            Start-Sleep -Milliseconds $Script:FileRetryDelayMs
        }
    }
}

function Read-SafeJson {
    <#
    .SYNOPSIS
        Read a JSON file with retry. Returns $null on failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    for ($i = 0; $i -lt $Script:MaxFileRetries; $i++) {
        try {
            $text = [System.IO.File]::ReadAllText($Path, $Script:Utf8NoBom)
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        } catch {
            if ($i -eq $Script:MaxFileRetries - 1) { return $null }
            Start-Sleep -Milliseconds $Script:FileRetryDelayMs
        }
    }
    return $null
}

function Read-SafeText {
    <#
    .SYNOPSIS
        Read a text file with retry. Returns $null on failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    for ($i = 0; $i -lt $Script:MaxFileRetries; $i++) {
        try {
            $text = [System.IO.File]::ReadAllText($Path, $Script:Utf8NoBom).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return $text
        } catch {
            if ($i -eq $Script:MaxFileRetries - 1) { return $null }
            Start-Sleep -Milliseconds $Script:FileRetryDelayMs
        }
    }
    return $null
}

# ══════════════════════════════════════════════════════════════════
# Logging
# ══════════════════════════════════════════════════════════════════

function Write-BridgeLog {
    <#
    .SYNOPSIS
        Append a timestamped log entry to the specified log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$LogFile
    )
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($LogFile, "$ts | $Message`r`n", $Script:Utf8NoBom)
    } catch {
        # Silent — logging failure should not crash the process
    }
}

# ══════════════════════════════════════════════════════════════════
# Heartbeat
# ══════════════════════════════════════════════════════════════════

function Write-Heartbeat {
    <#
    .SYNOPSIS
        Write current timestamp to a heartbeat file (atomic write).
    .DESCRIPTION
        Uses temp+rename to avoid 9P cache issues — same pattern as Write-SafeFile.
        Heartbeat files are polled by Guardian and other monitors; stale reads cause
        false "dead" detections.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $tmpPath = "$Path.tmp"
        [System.IO.File]::WriteAllText(
            $tmpPath,
            (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"),
            $Script:Utf8NoBom
        )
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    } catch { }
}

function Test-HeartbeatAlive {
    <#
    .SYNOPSIS
        Check if a heartbeat file is recent enough (within N seconds).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxAgeSeconds = 120
    )
    $hb = Read-SafeText -Path $Path
    if (-not $hb) { return $false }
    try {
        if ($hb -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}') {
            $hbTime = [datetime]::ParseExact($matches[0], "yyyy-MM-dd HH:mm:ss", $null)
            return ((Get-Date) - $hbTime).TotalSeconds -lt $MaxAgeSeconds
        }
    } catch { }
    return $false
}

# ══════════════════════════════════════════════════════════════════
# PID Lock
# ══════════════════════════════════════════════════════════════════

function Enter-PidLock {
    <#
    .SYNOPSIS
        Write current PID to a lock file (atomic write).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $tmpPath = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmpPath, [string]$PID, $Script:Utf8NoBom)
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    } catch { }
}

function Get-LockedPid {
    <#
    .SYNOPSIS
        Read the PID from a lock file. Returns $null if missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $text = Read-SafeText -Path $Path
    if ($text -and $text -match '^\d+$') { return [int]$text }
    return $null
}

# ══════════════════════════════════════════════════════════════════
# Queue helpers
# ══════════════════════════════════════════════════════════════════

function Reset-QueueToIdle {
    <#
    .SYNOPSIS
        Reset a queue file to the idle state.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Write-SafeFile -Path $Path -Content $Script:IdleQueueJson
}

function Get-IdleQueueJson {
    <#
    .SYNOPSIS
        Return the standard idle queue JSON string.
    #>
    return $Script:IdleQueueJson
}

# ══════════════════════════════════════════════════════════════════
# Result helpers
# ══════════════════════════════════════════════════════════════════

function New-CommandResult {
    <#
    .SYNOPSIS
        Build a standardized result hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CmdId,
        [int]$ExitCode = -1,
        [string]$Stdout = "",
        [string]$Stderr = "",
        [string]$Error = "",
        [int]$DurationMs = 0,
        [bool]$FastPath = $false,
        [bool]$PipeDirect = $false
    )
    return @{
        state       = "done"
        cmd_id      = $CmdId
        exit_code   = $ExitCode
        stdout      = $Stdout
        stderr      = $Stderr
        error       = $Error
        duration_ms = $DurationMs
        fast_path   = $FastPath
        pipe_direct = $PipeDirect
        timestamp   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    }
}

function Write-CommandResult {
    <#
    .SYNOPSIS
        Write a result object to a JSON file in the specified directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [Parameter(Mandatory)][string]$Directory
    )
    $path = Join-Path $Directory "r_$($Result.cmd_id).json"
    Write-SafeFile -Path $path -Content ($Result | ConvertTo-Json -Depth 1 -Compress)
    # Signal via EventWaitHandle
    try {
        $evt = [System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result")
        $evt.Set()
        $evt.Dispose()
    } catch { }
}

# ══════════════════════════════════════════════════════════════════
# Log rotation
# ══════════════════════════════════════════════════════════════════

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Trim a log file to a maximum number of lines (atomic write).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxLines = 500
    )
    if (-not (Test-Path $Path)) { return }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, $Script:Utf8NoBom)
        if ($lines.Count -gt $MaxLines) {
            $kept = $lines[($lines.Count - $MaxLines)..($lines.Count - 1)]
            $tmpPath = "$Path.tmp"
            [System.IO.File]::WriteAllLines($tmpPath, $kept, $Script:Utf8NoBom)
            Move-Item -LiteralPath $tmpPath -Destination $Path -Force
        }
    } catch { }
}

# ── Export all functions ──
Export-ModuleMember -Function @(
    'Write-SafeFile',
    'Read-SafeJson',
    'Read-SafeText',
    'Write-BridgeLog',
    'Write-Heartbeat',
    'Test-HeartbeatAlive',
    'Enter-PidLock',
    'Get-LockedPid',
    'Reset-QueueToIdle',
    'Get-IdleQueueJson',
    'New-CommandResult',
    'Write-CommandResult',
    'Invoke-LogRotation'
)
