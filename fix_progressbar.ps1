# Fix ProgressBar - replace inline with framework import
# PS 5.1 safe: use [IO.File]::ReadAllText to preserve UTF-8

$utf8 = [System.Text.UTF8Encoding]::new($false)
$files = @(
    "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\dashboard.py",
    "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\cluster.py"
)

foreach ($path in $files) {
    $content = [System.IO.File]::ReadAllText($path, $utf8)
    $changed = $false

    # 1. Add ProgressBar import after layout import
    $importLine = "from skia_framework.components.layout import Row, Column, Spacer"
    $newImport = "from skia_framework.components.layout import Row, Column, Spacer`r`nfrom skia_framework.components.progressbar import ProgressBar"

    if ($content -notmatch "from skia_framework.components.progressbar") {
        $content = $content -replace [regex]::Escape($importLine), $newImport
        Write-Output "${path}: Added ProgressBar import"
        $changed = $true
    } else {
        Write-Output "${path}: ProgressBar already imported"
    }

    # 2. Remove inline ProgressBar class
    # Match from 'class ProgressBar(Widget):' through its body until next class/def at col 0
    $pattern = '(?s)class ProgressBar\(Widget\):.*?(?=(?:\r?\n){2,}(?:class |def |\Z|from |import |#))'
    $newContent = $content -replace $pattern, ''
    if ($newContent -ne $content) {
        # Clean up extra blank lines
        $newContent = $newContent -replace '(\r?\n){3,}', "`r`n`r`n"
        $content = $newContent
        Write-Output "${path}: Removed inline ProgressBar"
        $changed = $true
    } else {
        Write-Output "${path}: WARNING - inline ProgressBar not found"
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($path, $content, $utf8)
    }
}

Write-Output "=== Done ==="
