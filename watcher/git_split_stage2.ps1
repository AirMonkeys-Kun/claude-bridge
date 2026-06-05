$br = "D:\zebbingo\tools\claude-bridge"
$cfg = "D:\zebbingo\tools\claude-desktop-config"

Write-Output "=== 1. Remove lock files from tracking ==="
git -C $br rm --cached cluster/file_bridge/.lock 2>$null
git -C $br rm --cached cluster/process_bridge/.lock 2>$null
git -C $br rm --cached cluster/system_bridge/.lock 2>$null
git -C $br rm --cached cluster/wsl_bridge/.lock 2>$null
Write-Output "Lock files removed from tracking"

Write-Output ""
Write-Output "=== 2. Remove memory/ from tracking (runtime content) ==="
git -C $br rm --cached -r memory/ 2>$null
Write-Output "Done"

Write-Output ""
Write-Output "=== 3. Final status before commit ==="
git -C $br status --short

Write-Output ""
Write-Output "=== 4. Committing proxy split ==="
git -C $br add -A
git -C $br commit -m "chore: complete proxy split — remove proxy files, legacy stubs, lock files

Proxy files (proxy_server.py, launch_proxy.py, config.yaml, .env, etc.)
have been physically moved to claude-desktop-config/proxy/ where they
belong. The proxy project is now a separate git repository.

This commit:
- Removes all proxy-related files from tracking
- Removes legacy stub directories (backend-integration/, etc.)
- Removes runtime lock files from tracking
- Updates .gitignore with proxy/lock patterns
- Adds newly tracked bridge components (vsock doorbell, etc.)
- Adds git split scripts and migration docs"
Write-Output "Commit done"

Write-Output ""
Write-Output "=== 5. Push to remote ==="
$remote = git -C $br remote get-url origin 2>$null
if ($remote) {
    Write-Output "Remote: $remote"
    git -C $br push 2>&1
    Write-Output "Push done"
} else {
    Write-Output "No remote configured, skipping push"
}

Write-Output ""
Write-Output "=== 6. Initialize claude-desktop-config repo ==="
if (Test-Path "$cfg\.git") {
    Write-Output "Already a git repo"
} else {
    Write-Output "Initializing..."
    git -C $cfg init
    Write-Output "Git init done"
}

Write-Output ""
Write-Output "=== 7. Create .gitignore for claude-desktop-config ==="
$cgi = @(
    "# --- Runtime ---",
    "*.log",
    "logs/",
    "",
    "# --- Python ---",
    "__pycache__/",
    "*.pyc",
    "*.pyo",
    "",
    "# --- Editor ---",
    ".vscode/",
    ".idea/",
    "*.swp",
    "*.swo",
    ".DS_Store",
    "Thumbs.db"
)
Set-Content "$cfg\.gitignore" -Value $cgi
Write-Output ".gitignore created"

Write-Output ""
Write-Output "=== 8. Stage and commit claude-desktop-config ==="
git -C $cfg add -A
$cfgFiles = git -C $cfg status --short
$cfgCount = ($cfgFiles | Measure-Object | Select-Object -ExpandProperty Count)
Write-Output "Files to commit: $cfgCount"
$cfgFiles

git -C $cfg commit -m "Initial commit: proxy server + claude-desktop-config

This repository contains the Claude Desktop configuration and proxy server
project, separated from the claude-bridge repository.

Origin:
- proxy_server.py, config.yaml, launch_proxy.py originally from claude-bridge
  commit 9d8e9a3 (V3 pipe-direct worker pool + parallel dispatcher)
- Separated on 2026-06-05 into its own repository

Contents:
- claude_desktop_config.json — Cowork provider configuration
- proxy/server.py — Local API proxy (port 4000) for Anthropic API conversion
- proxy/v6/server_v6.py — V6 optional variant
- proxy/config.yaml, proxy/.env — Proxy configuration
- proxy/launch.py — Proxy launcher
- proxy/restart.ps1 — Restart utility
- proxy/memory/ — Proxy design notes and history
- PROVIDERS.md, setup_direct.ps1 — Direct connection setup
- HISTORY.md — Provider config history"
Write-Output "Commit done"
