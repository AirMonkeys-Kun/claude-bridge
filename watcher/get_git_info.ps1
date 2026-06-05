$bridge = "D:\zebbingo\tools\claude-bridge"
$config = "D:\zebbingo\tools\claude-desktop-config"

Write-Output "=== CLAUDE-BRIDGE GIT LOG (FULL) ==="
git -C $bridge log --oneline --reverse
Write-Output ""

Write-Output "=== INITIAL COMMIT FILES ==="
$init = git -C $bridge rev-list --max-parents=0 HEAD
git -C $bridge diff-tree --no-commit-id -r $init
Write-Output ""

Write-Output "=== FILES WITH 'proxy' IN HISTORY ==="
git -C $bridge log --all --diff-filter=A --name-only --format="" -- "*proxy*" | Select-Object -Unique | Where-Object { $_ -ne "" }
Write-Output ""

Write-Output "=== CLAUDE-DESKTOP-CONFIG STATUS ==="
if (Test-Path "$config\.git") {
    git -C $config log --oneline -10
} else {
    Write-Output "Not a git repository"
    Write-Output ""
    Get-ChildItem $config -Name
}
