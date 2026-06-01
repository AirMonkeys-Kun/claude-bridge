# Fix sys.path.insert in cluster.py (two-line to one-line)
$utf8 = [System.Text.UTF8Encoding]::new($false)
$path = "C:\Users\wsx\Documents\SmartAgent\applications\skia_gui\cluster.py"

$content = [System.IO.File]::ReadAllText($path, $utf8)
Write-Output "File loaded, length=$($content.Length)"

# Find the two-line pattern more flexibly
$old1 = 'sys.path.insert(0, str(Path(__file__).parent.parent.parent))'
$old2 = 'sys.path.insert(0, str(Path(__file__).parent.parent))'
$newLine = 'sys.path.insert(0, str(Path(__file__).parent.parent))  # adds applications/'

# Method: Replace the two consecutive lines (handles both \r\n and \n)
$pattern = [regex]::Escape($old1) + '\r?\n' + [regex]::Escape($old2)
$newContent = $content -replace $pattern, $newLine

if ($newContent -ne $content) {
    [System.IO.File]::WriteAllText($path, $newContent, $utf8)
    Write-Output "Fixed: sys.path lines merged"
} else {
    # Try with just \n (maybe Unix line endings)
    $pattern = [regex]::Escape($old1) + '\n' + [regex]::Escape($old2)
    $newContent = $content -replace $pattern, $newLine
    if ($newContent -ne $content) {
        [System.IO.File]::WriteAllText($path, $newContent, $utf8)
        Write-Output "Fixed: sys.path lines merged (Unix)"
    } else {
        Write-Output "WARNING: Pattern not found in file"
        # Show what's around that area for debugging
        $idx = $content.IndexOf('sys.path')
        if ($idx -ge 0) {
            Write-Output "Context at sys.path: ---${content.Substring($idx, 120)}---"
        }
    }
}

Write-Output "=== Done ==="
