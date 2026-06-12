# ══════════════════════════════════════════════════════════════════
# Logging — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Log { param([string]$m)
    try {
        # Auto-rotate when log exceeds 2MB
        try {
            if ((Get-Item $script:logFile -ErrorAction SilentlyContinue).Length -gt 2MB) {
                $rotated = $script:logFile -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                Move-Item $script:logFile $rotated -Force -ErrorAction SilentlyContinue
                [System.IO.File]::AppendAllText($script:logFile, "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')) | [LOG-ROTATE] Rotated to $rotated`r`n", $script:utf8)
            }
        } catch { }
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($script:logFile, "$ts | $m`r`n", $script:utf8)
        # NOTE: Do NOT add Write-BridgeLog here — this is the core Log function,
        # every V22+ handler calls it. Adding Write-BridgeLog would double-write
        # every line (both here AND in Write-BridgeLog) because appendalltext writes
        # directly while Write-BridgeLog does its own write via Write-SafeFile.
        # See powershell-best-practices.md: "logging single-writer pattern"
    } catch {
        try {
            $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            # Primary fallback: .watcher_fallback.log in watcher dir
            $fallbackPath = Join-Path $script:baseDir ".watcher_fallback.log"
            try {
                [System.IO.File]::AppendAllText($fallbackPath, "$t | LOG_FAIL: $($_.Exception.Message)`r`n", $script:utf8)
                [System.IO.File]::AppendAllText($fallbackPath, "$t | ORIGINAL: $m`r`n", $script:utf8)
     