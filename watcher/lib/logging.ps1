# ══════════════════════════════════════════════════════════════════
# Logging — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Log { param([string]$m)
    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($script:logFile, "$ts | $m`r`n", $script:utf8)
        # Best-effort: also attempt module-based Write-BridgeLog (silently ignores if module broken)
        try { Write-BridgeLog -Message $m -LogFile $script:logFile } catch { }
    } catch {
        try {
            $fallbackPath = Join-Path $script:baseDir ".watcher_fallback.log"
            $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            [System.IO.File]::AppendAllText($fallb