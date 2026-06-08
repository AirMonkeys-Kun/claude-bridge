# ══════════════════════════════════════════════════════════════════
# Content-hash dedup — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

$script:contentDedup = @{}
$script:dedupTtlSec = 60  # 60-second dedup window

function Add-ContentDedup {
    <#.SYNOPSIS Store command content hash for future dedup.#>
    param([string]$CmdText, [string]$CmdId)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CmdText)
        $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $hash = [System.Convert]::ToBase64String($hashBytes)
        $script:contentDedup[$hash] = @{
            cmd_id    = $CmdId
            timestamp = (Get-Date)
        }
    } catch {
        # Silent — dedup failure should not crash
    }
}

function Get-ContentDedup {
    <#.SYNOPSIS Look up command content hash. Returns $null if no hit or expired.#>
    param([string]$CmdText)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($CmdText)
        $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
        $hash = [System.Convert]::ToBase64String($hashBytes)
        if ($script:contentDedup.ContainsKey($hash)) {
            $entry = $script:contentDedup[$hash]
            $ageSec = [int]((Get-Date) - $entry.timestamp).TotalSeconds
            if ($ageSec -le $script:dedupTtlSec) {
                return $entry
            } else {
                $script:contentDedup.Remove($hash)
            }
        }
    } catch {
        # Silent
    }
    return $null
}

function Invoke-HandleDedup {
    <#.SYNOPSIS Check content-hash dedup. Returns $true if dedup hit (command skipped).#>
    param([string]$CmdId, [string]$RawCmd)
    $dedupHit = Get-ContentDedup $RawCmd
    if (-not $dedupHit) { return $false }

    $ageMs = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
    Log "[$CmdId] CONTENT-HASH HIT: '$($RawCmd.Substring(0,[Math]::Min(80,$RawCmd.Length)))' = $($dedupHit.cmd_id) (${ageMs}ms ago) — reusing result"
    $cachedFile = Join-Path $script:baseDir "r_$($dedupHit.cmd_id).json"
    if (Test-Path $cachedFile) {
        try {
            $cachedContent = [System.IO.File]::ReadAllText($cachedFile, $script:utf8)
            $cachedParsed = ($cachedContent | ConvertFrom-Json)
            $cachedParsed.cmd_id = $CmdId
            $cachedParsed.duration_ms = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
            Write-Text -path (Join-Path $script:baseDir "r_${CmdId}.json") -content ($cachedParsed | ConvertTo-Json -Compress)
        } catch {
            Log "[$CmdId] CONTENT-HASH cache read failed: $_ — proceeding with execution"
            return $false
        }
    }
    Reset-QueueToIdle -Path $script:queueFile
    return $true
}

function Invoke-ContentDedupCleanup {
    <#.SYNOPSIS Purge expired entries from content dedup store (called from housekeeping).#>
    $now = Get-Date
    $expired = @($script:contentDedup.Keys | Where-Object {
        ($now - $script:contentDedup[$_].timestamp).TotalSeconds -gt $script:dedupTtlSec
    })
    foreach ($key in $expired) { $script:contentDedup.Remove($key) }
}
