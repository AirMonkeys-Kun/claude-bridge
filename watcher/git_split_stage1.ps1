$br = "D:\zebbingo\tools\claude-bridge"

Write-Output "=== 1. Update .gitignore ==="
$gi = Get-Content "$br\.gitignore"
$add = @(
    "# --- Proxy (moved to claude-desktop-config) ---",
    "proxy*",
    "config.yaml",
    "config_v*.yaml*",
    ".env",
    "*.archived",
    "",
    "# --- Legacy stub dirs (moved to docs/legacy/) ---",
    "backend-integration/",
    "frontend-integration/",
    "profile-system/",
    "startup-scripts/",
    "",
    "# --- Lock files ---",
    "*.lock",
    ".lock"
)
$new = $gi + $add | Select-Object -Unique
Set-Content "$br\.gitignore" -Value $new
Write-Output ".gitignore updated"

Write-Output ""
Write-Output "=== 2. Stage all changes ==="
git -C $br add -A 2>&1
Write-Output "git add -A done"

Write-Output ""
Write-Output "=== 3. Status after stage ==="
git -C $br status --short
