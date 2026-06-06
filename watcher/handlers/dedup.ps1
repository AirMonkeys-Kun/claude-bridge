# ══════════════════════════════════════════════════════════════════
# Content-hash dedup — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Add-ContentDedup { param([string]$CmdText, [string]$CmdId) }
function Get-ContentDedup { param([string]$CmdText) return $null }

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
