# Fix main.py after encoding restore (was excluded from fix_skia_imports)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$path = "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\main.py"

$content = [System.IO.File]::ReadAllText($path, $utf8)
$changed = $false

# 1. Fix docstring run path
$content = $content -replace [regex]::Escape("python experiments/skia_gui/main.py"), "python applications/skia_gui/main.py"

# 2. Fix sys.path lines (two-line to one-line)
$old1 = 'sys.path.insert(0, str(Path(__file__).parent.parent.parent))'
$old2 = 'sys.path.insert(0, str(Path(__file__).parent.parent))'
$newLine = 'sys.path.insert(0, str(Path(__file__).parent.parent))  # adds applications/'

$pattern = [regex]::Escape($old1) + '\r?\n' + [regex]::Escape($old2)
$newContent = $content -replace $pattern, $newLine
if ($newContent -ne $content) {
    $content = $newContent
    $changed = $true
    Write-Output "sys.path fixed"
}

[System.IO.File]::WriteAllText($path, $content, $utf8)
Write-Output "main.py fixed"

Write-Output "=== Done ==="
