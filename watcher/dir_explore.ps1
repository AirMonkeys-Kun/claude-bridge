# 探索 LEVEL 2 - 看 Claude-3p 深层目录
# 通过桥接器执行 - 列出 claude-code 和 sessions 子目录
$logFile = "C:\Users\wsx\Desktop\claude-bridge\watcher\dir_explore.txt"
$ErrorActionPreference = "Continue"
$script:lines = @()

function Log { param($m) $script:lines += $m; Write-Host $m }

Log "=== Claude-3p directory deep listing ==="

$base = "$env:LOCALAPPDATA\Claude-3p"

# List top-level
Log "`n=== Top level: $base ==="
foreach ($item in Get-ChildItem $base) {
    Log "$($item.Name) ($($item.Mode))"
}

# Recursively list everything
Log "`n=== Full recursive listing ==="
Get-ChildItem $base -Recurse -Depth 5 -ErrorAction SilentlyContinue | ForEach-Object {
    Log "$($_.FullName.Replace($base,'')) ($($_.Length) bytes)"
}

# Also check Roaming
$roaming = "$env:APPDATA\Claude-3p"
if (Test-Path $roaming) {
    Log "`n=== Roaming: $roaming ==="
    Get-ChildItem $roaming -Recurse -Depth 5 -ErrorAction SilentlyContinue | ForEach-Object {
        Log "$($_.FullName.Replace($roaming,'')) ($($_.Length) bytes)"
    }
}

# Check other possible locations
$otherPaths = @(
    "$env:LOCALAPPDATA\Cowork",
    "$env:APPDATA\Cowork",
    "$env:USERPROFILE\.claude",
    "$env:LOCALAPPDATA\claude-desktop",
    "$env:LOCALAPPDATA\Programs\Claude"
)
foreach ($p in $otherPaths) {
    if (Test-Path $p) {
        Log "`n=== EXISTS: $p ==="
        Get-ChildItem $p -Recurse -Depth 5 -ErrorAction SilentlyContinue | ForEach-Object {
            Log "$($_.FullName) ($($_.Length) bytes)"
        }
    } else {
        Log "`n=== NOT EXISTS: $p ==="
    }
}

$script:lines | Out-File $logFile -Encoding utf8
Write-Host "`nSaved to: $logFile"
