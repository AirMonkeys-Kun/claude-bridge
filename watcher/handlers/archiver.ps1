# ══════════════════════════════════════════════════════════════════
# Archiver handler — structured log/result file archiving (V1.0)
# ══════════════════════════════════════════════════════════════════
# Design:
#   archive/
#     results/YYYY-MM/YYYY-MM-DD/   — r_*.json by creation date
#     logs/                          — rotated .log files (gzip'd)
#   Retention:
#     results:  purge >30d
#     logs:     compress >1d, purge >60d
#   Trigger:    Invoke-Archive every 300 housekeeping loops (~60s)
# ══════════════════════════════════════════════════════════════════

$script:archiveBase = Join-Path $script:baseDir "archive"
$script:archiveResults = Join-Path $script:archiveBase "results"
$script:archiveLogs = Join-Path $script:archiveBase "logs"

# ── Ensure archive directories exist ──
function Initialize-ArchiveDirs {
    foreach ($d in @($script:archiveBase, $script:archiveResults, $script:archiveLogs)) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }
}

# ── Archive old result files (r_*.json) ──
function Invoke-ArchiveResults {
    param([int]$MaxAgeHours = 1)
    Initialize-ArchiveDirs
    $cutoff = (Get-Date).AddHours(-$MaxAgeHours)
    $archived = 0; $size = 0

    $files = Get-ChildItem (Join-Path $script:baseDir "r_*.json") -ErrorAction SilentlyContinue `
        | Where-Object { $_.LastWriteTime -lt $cutoff }

    foreach ($f in $files) {
        $dateDir = $f.LastWriteTime.ToString("yyyy-MM-dd")
        $monthDir = $f.LastWriteTime.ToString("yyyy-MM")
        $targetDir = Join-Path (Join-Path $script:archiveResults $monthDir) $dateDir
        if (-not (Test-Path $targetDir)) { New-Item -Path $targetDir -ItemType Directory -Force | Out-Null }
        $target = Join-Path $targetDir $f.Name
        try {
            Move-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
            $archived++; $size += $f.Length
        } catch { Log "[ARCHIVE] Failed to move $($f.Name): $_" }
    }
    if ($archived -gt 0) { Log "[ARCHIVE] Archived $archived result files ($([math]::Round($size/1KB,1)) KB) → $($script:archiveResults)" }
    return $archived
}

# ── Archive rotated log files ──
function Invoke-ArchiveRotatedLogs {
    Initialize-ArchiveDirs
    $archived = 0; $size = 0

    # Match rotated log patterns: watcher_YYYYMMDD_*.log or *._*.log
    $patterns = @("watcher_*.log", "guardian_v3_*.log", "*.log.old", "*_*.log")
    $files = @()
    foreach ($p in $patterns) {
        $files += Get-ChildItem (Join-Path $script:baseDir $p) -ErrorAction SilentlyContinue
    }

    # Exclude current active logs
    $activeLogs = @("watcher.log", "guardian_v3.log", "ba_start.log", "bridge_agent_stdout.log", "bridge_agent_stderr.log", "factory_out.log", "factory_err.log")
    $files = $files | Where-Object { $activeLogs -notcontains $_.Name }

    foreach ($f in $files) {
        $monthDir = $f.LastWriteTime.ToString("yyyy-MM")
        $targetDir = Join-Path $script:archiveLogs $monthDir
        if (-not (Test-Path $targetDir)) { New-Item -Path $targetDir -ItemType Directory -Force | Out-Null }

        # Compress with .NET GZip for rotated logs >100KB
        $target = Join-Path $targetDir "$($f.BaseName).log.gz"
        if ($f.Length -gt 100KB -and $f.Extension -ne '.gz') {
            try {
                $gzTarget = Join-Path $targetDir "$($f.BaseName).log.gz"
                $buffer = [System.IO.File]::ReadAllBytes($f.FullName)
                $gzStream = [System.IO.Compression.GZipStream]::new(
                    [System.IO.File]::Open($gzTarget, [System.IO.FileMode]::Create),
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $gzStream.Write($buffer, 0, $buffer.Length)
                $gzStream.Close()
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                $archived++; $size += $f.Length
                Log "[ARCHIVE] Compressed $($f.Name) ($([math]::Round($buffer.Length/1KB,1)) KB → $([math]::Round((Get-Item $gzTarget).Length/1KB,1)) KB)"
            } catch { Log "[ARCHIVE] Compress failed for $($f.Name): $_" }
        } else {
            try {
                Move-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
                $archived++; $size += $f.Length
            } catch { Log "[ARCHIVE] Move failed for $($f.Name): $_" }
        }
    }
    if ($archived -gt 0) { Log "[ARCHIVE] Archived $archived rotated logs ($([math]::Round($size/1KB,1)) KB) → $script:archiveLogs" }
    return $archived
}

# ── Purge archives older than retention ──
function Invoke-PurgeArchives {
    param([int]$ResultRetentionDays = 30, [int]$LogRetentionDays = 60)

    $purged = 0; $freed = 0

    # Purge old result archives
    $resultCutoff = (Get-Date).AddDays(-$ResultRetentionDays)
    $oldResultDirs = Get-ChildItem $script:archiveResults -Directory -Recurse -ErrorAction SilentlyContinue `
        | Where-Object { $_.LastWriteTime -lt $resultCutoff -and $_.GetFiles().Count -eq 0 -and $_.GetDirectories().Count -eq 0 }
    foreach ($d in $oldResultDirs) {
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $purged++ } catch {}
    }
    # Also purge old date-named files directly
    $oldResultFiles = Get-ChildItem (Join-Path $script:archiveResults "*\*.json") -ErrorAction SilentlyContinue `
        | Where-Object { $_.LastWriteTime -lt $resultCutoff }
    foreach ($f in $oldResultFiles) {
        $freed += $f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $purged++
    }

    # Purge old log archives
    $logCutoff = (Get-Date).AddDays(-$LogRetentionDays)
    $oldLogFiles = Get-ChildItem (Join-Path $script:archiveLogs "*\*.gz") -ErrorAction SilentlyContinue `
        | Where-Object { $_.LastWriteTime -lt $logCutoff }
    foreach ($f in $oldLogFiles) {
        $freed += $f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $purged++
    }

    # Clean empty month dirs
    $emptyDirs = Get-ChildItem $script:archiveLogs -Directory -ErrorAction SilentlyContinue `
        | Where-Object { (Get-ChildItem $_.FullName -Recurse -File).Count -eq 0 }
    foreach ($d in $emptyDirs) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {} }

    if ($purged -gt 0) { Log "[ARCHIVE] Purged $purged expired archive entries ($([math]::Round($freed/1KB,1)) KB freed)" }
    return $purged
}

# ── One-shot: archive everything older than 1h ──
function Invoke-Archive {
    param(
        [int]$ResultAgeHours = 1,
        [int]$ResultRetentionDays = 30,
        [int]$LogRetentionDays = 60,
        [switch]$Purge
    )
    try { $r1 = Invoke-ArchiveResults -MaxAgeHours $ResultAgeHours } catch { Log "[ARCHIVE] ArchiveResults error: $_" }
    try { $r2 = Invoke-ArchiveRotatedLogs } catch { Log "[ARCHIVE] ArchiveRotatedLogs error: $_" }
    if ($Purge) { try { Invoke-PurgeArchives -ResultRetentionDays $ResultRetentionDays -LogRetentionDays $LogRetentionDays } catch { Log "[ARCHIVE] Purge error: $_" } }
    return ($r1 -gt 0 -or $r2 -gt 0)
}

# ── Manual archive command (for queue dispatch) ──
function Invoke-ArchiveNow {
    param([switch]$Purge)
    $start = Get-Date
    $r = Invoke-Archive -Purge:$Purge
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    Log "[ARCHIVE] Archive cycle complete in ${elapsed}s — archived=$r"
}

# ── Init ──
Initialize-ArchiveDirs
Log "Archiver V1 loaded (archiveBase=$script:archiveBase)"
