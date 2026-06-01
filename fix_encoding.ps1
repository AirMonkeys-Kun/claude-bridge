# Fix UTF-8 encoding: restore from experiments/, re-apply all fixes
# PS 5.1 safe: uses [IO.File]::ReadAllText with explicit UTF-8
param(
    [switch]$DryRun
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
$srcBase = "C:\Users\wsx\Documents\SmartAgent\experiments\skia_gui"
$dstBase = "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui"

# ── Step 1: Copy ALL files from experiments/ to applications/ (restores UTF-8) ──
$allFiles = @(
    "__init__.py", "main.py",
    "dashboard.py", "services.py", "monitor.py", "log_viewer.py",
    "env.py", "config.py", "settings.py", "cluster.py",
    "ai_model_manager.py", "ai_agent_chat.py", "service_store.py"
)

foreach ($f in $allFiles) {
    $src = Join-Path $srcBase $f
    $dst = Join-Path $dstBase $f
    if (-not (Test-Path $src)) {
        Write-Output "SKIP $f (not in experiments/)"
        continue
    }
    if (-not (Test-Path $dst)) {
        Write-Output "SKIP $f (not in applications/)"
        continue
    }
    if ($DryRun) {
        Write-Output "WOULD copy: $f"
        continue
    }
    $content = [System.IO.File]::ReadAllText($src, $utf8)
    [System.IO.File]::WriteAllText($dst, $content, $utf8)
    Write-Output "Restored: $f"
}

# ── Step 2: Fix sys.path.insert + docstring run paths ──
$fixFiles = @(
    "dashboard.py", "services.py", "monitor.py", "log_viewer.py",
    "env.py", "config.py", "settings.py", "cluster.py",
    "ai_model_manager.py", "ai_agent_chat.py"
)

$oldPathHack = @"
sys.path.insert(0, str(Path(__file__).parent.parent.parent))
sys.path.insert(0, str(Path(__file__).parent.parent))
"@

$newPathHack = "sys.path.insert(0, str(Path(__file__).parent.parent))  # adds applications/"

foreach ($f in $fixFiles) {
    $path = Join-Path $dstBase $f
    if (-not (Test-Path $path)) { continue }
    if ($DryRun) { Write-Output "WOULD fix imports: $f"; continue }
    $content = [System.IO.File]::ReadAllText($path, $utf8)
    $changed = $false

    # Fix docstring run path (experiments/ → applications/)
    $oldRun = "python experiments/skia_gui/"
    $newRun = "python applications/skia_gui/"
    $content = $content -replace [regex]::Escape($oldRun), $newRun

    # Fix sys.path lines (two-line → one-line)
    $newContent = $content -replace [regex]::Escape($oldPathHack), $newPathHack
    if ($newContent -ne $content) {
        $content = $newContent
        $changed = $true
    }

    [System.IO.File]::WriteAllText($path, $content, $utf8)
    Write-Output "  ${f}: imports fixed"
}

# ── Step 3: Fix ProgressBar (add framework import, remove inline class) ──
$pbFiles = @(
    "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\dashboard.py",
    "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\cluster.py"
)
$importLine = "from skia_framework.components.layout import Row, Column, Spacer"
$newImport = "from skia_framework.components.layout import Row, Column, Spacer`r`nfrom skia_framework.components.progressbar import ProgressBar"

foreach ($path in $pbFiles) {
    if ($DryRun) { Write-Output "WOULD fix ProgressBar: $path"; continue }
    $content = [System.IO.File]::ReadAllText($path, $utf8)
    $changed = $false

    # Add ProgressBar import
    if ($content -notmatch "from skia_framework.components.progressbar") {
        $content = $content -replace [regex]::Escape($importLine), $newImport
        $changed = $true
    }

    # Remove inline ProgressBar class
    $pattern = '(?s)class ProgressBar\(Widget\):.*?(?=(?:\r?\n){2,}(?:class |def |\Z|from |import |#))'
    $newContent = $content -replace $pattern, ''
    if ($newContent -ne $content) {
        $newContent = $newContent -replace '(\r?\n){3,}', "`r`n`r`n"
        $content = $newContent
        $changed = $true
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($path, $content, $utf8)
        Write-Output "  ProgressBar fixed: $path"
    } else {
        Write-Output "  No changes needed: $path"
    }
}

Write-Output "=== Done ==="
