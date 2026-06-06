# ══════════════════════════════════════════════════════════════════
# Logging — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Log { param([string]$m)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($script:logFile, "$ts | $m`r`n", $script:utf8)
        # NOTE: Do NOT add Write-BridgeLog here — this is the core Log function,
        # every V22+ handler calls it. Adding Write-BridgeLog would double-write
        # every line (both here AND in Write-BridgeLog) because appendalltext writes
        # directly while Write-BridgeLog does its own write via Write-SafeFile.
        # See powershell-best-practices.md: "logging single-writer patt