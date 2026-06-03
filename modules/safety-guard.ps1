#Requires -Version 5.0
<#
safety-guard.ps1 — content dedup + inflight guard (V18, from watcher V13)
  Content dedup:  Same command text within 2min → reuse cached result.
  Inflight guard: Only one command executes at a time → reject duplicates.
  Exports:        Test-Dedup, Add-Dedup, Set-Inflight, Clear-Inflight, Test-Inflight
#>

. "$PSScriptRoot\bridge-core.ps1"

# ── Content dedup cache ───────────────────────────────────────────────
$script:dedupCache = @{}           # cmd_text_hash → @{cmd_id, timestamp}
$script:dedupMaxAgeMs = 120000     # 2 min TTL
$script:dedupMaxSize  = 100        # max cache entries

# ── Inflight guard state ──────────────────────────────────────────────
$script:inflightCmdId = ""         # currently executing cmd_id
$script:inflightSince = $null      # when inflight started
$script:inflightTimeout = 300      # max seconds a command can be inflight

# ── Check content dedup ───────────────────────────────────────────────
# Returns: $null if no hit, or @{cmd_id, timestamp} if cached
function Test-Dedup { param([string]$CmdText)
    if ([string]::IsNullOrWhiteSpace($CmdText)) { return $null }
    $key = $CmdText.Substring(0, [Math]::Min(300, $CmdText.Length))
    if ($script:dedupCache.ContainsKey($key)) {
        $elapsed = [int]((Get-Date) - $script:dedupCache[$key].timestamp).TotalMilliseconds
        if ($elapsed -lt $script:dedupMaxAgeMs) {
            return $script:dedupCache[$key]
        } else {
            $script:dedupCache.Remove($key)
        }
    }
    return $null
}

# ── Add to dedup cache ────────────────────────────────────────────────
function Add-Dedup { param([string]$CmdText, [string]$CmdId)
    if ([string]::IsNullOrWhiteSpace($CmdText)) { return }
    $key = $CmdText.Substring(0, [Math]::Min(300, $CmdText.Length))
    $script:dedupCache[$key] = @{cmd_id=$CmdId; timestamp=(Get-Date)}

    # Prune if over max
    if ($script:dedupCache.Count -gt $script:dedupMaxSize) {
        $sorted = $script:dedupCache.GetEnumerator() | Sort-Object { $_.Value.timestamp }
        $toRemove = $sorted | Select-Object -First ($script:dedupCache.Count - $script:dedupMaxSize)
        foreach ($e in $toRemove) { $script:dedupCache.Remove($e.Key) }
    }
}

# ── Try to reuse cached result ────────────────────────────────────────
# Returns: $true if cached result was written, $false otherwise
function Try-ReuseDedupResult {
    param(
        [string]$CmdText,
        [string]$CmdId
    )
    $dedupHit = Test-Dedup $CmdText
    if (-not $dedupHit) { return $false }

    $ageMs = [int]((Get-Date) - $dedupHit.timestamp).TotalMilliseconds
    Log "[$CmdId] DEDUP-HIT: same as $($dedupHit.cmd_id) (${ageMs}ms ago)"

    $cachedFile = Join-Path $script:resultDir "r_$($dedupHit.cmd_id).json"
    if (Test-Path $cachedFile) {
        try {
            $cachedContent = [System.IO.File]::ReadAllText($cachedFile, $script:utf8)
            $cachedParsed = ($cachedContent | ConvertFrom-Json)
            $cachedParsed.cmd_id = $CmdId
            $cachedParsed.duration_ms = $ageMs
            Write-File (Join-Path $script:resultDir "r_${CmdId}.json") ($cachedParsed | ConvertTo-Json -Compress)
            return $true
        } catch {
            Log "[$CmdId] Dedup cache read failed: $_"
        }
    }
    return $false
}

# ── Set inflight state ────────────────────────────────────────────────
function Set-Inflight { param([string]$CmdId)
    $script:inflightCmdId = $CmdId
    $script:inflightSince = Get-Date
}

# ── Clear inflight state ──────────────────────────────────────────────
function Clear-Inflight {
    $script:inflightCmdId = ""
    $script:inflightSince = $null
}

# ── Check inflight: returns $null if clear, cmd_id if busy ────────────
function Test-Inflight {
    if ([string]::IsNullOrWhiteSpace($script:inflightCmdId)) { return $null }
    if ($script:inflightSince) {
        $elapsed = [int]((Get-Date) - $script:inflightSince).TotalSeconds
        if ($elapsed -gt $script:inflightTimeout) {
            Log "[INFLIGHT] Expired: $($script:inflightCmdId) (${elapsed}s > ${$script:inflightTimeout}s) — clearing"
            Clear-Inflight
            return $null
        }
    }
    return $script:inflightCmdId
}

Log "safety-guard loaded: dedup=$($script:dedupMaxAgeMs)ms inflight=$($script:inflightTimeout)s"
