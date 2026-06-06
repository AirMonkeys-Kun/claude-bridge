# ══════════════════════════════════════════════════════════════════
# Logging — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Log { param([string]$m)
    try {
        Write-BridgeLog -Message $m -LogFile $script:logFile
    } catch {
        try {
            $fallbackPath = Join-Path $script:baseDir ".watcher_fallback.log"
            $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            [System.IO.File]::AppendAllText($fallbackPath, "$t | LOG_FAIL: $($_.Exception.Message)`r`n", $script:utf8)
            [System.IO.File]::AppendAllText($fallbackPath, "$t | ORIGINAL: $m`r`n", $script:utf8)
        } catch {}
    }
}
Set-Alias Write-Text  Write-SafeFile
Set-Alias Read-Json   Read-SafeJson
