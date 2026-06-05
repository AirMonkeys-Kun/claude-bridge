# Round 2: Complete separation — move proxy from claude-bridge to claude-desktop-config
$bridgeRoot = "D:\zebbingo\tools\claude-bridge"
$configRoot = "D:\zebbingo\tools\claude-desktop-config"

Write-Output "=========================================="
Write-Output "Round 2: Cutting proxy from bridge"
Write-Output "  bridge: $bridgeRoot"
Write-Output "  config: $configRoot"
Write-Output "=========================================="
Write-Output ""

# 1. Create proxy/ subdirectory in claude-desktop-config
New-Item -ItemType Directory -Force -Path "$configRoot\proxy\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "$configRoot\proxy\memory" | Out-Null
New-Item -ItemType Directory -Force -Path "$configRoot\proxy\v6" | Out-Null
Write-Output "=== Created proxy/ in claude-desktop-config ==="

# 2. Move proxy files FROM bridge/proxy/ TO config/proxy/
$moveFrom = "$bridgeRoot\proxy"
$moveTo   = "$configRoot\proxy"

if (Test-Path $moveFrom) {
    Write-Output "=== Moving files from bridge/proxy/ to config/proxy/ ==="

    # Main files
    @("server.py", "config.yaml", ".env", "launch.py", "restart.ps1") | ForEach-Object {
        $src = "$moveFrom\$_"
        if (Test-Path $src) {
            Move-Item -Path $src -Destination "$moveTo\$_" -Force
            Write-Output "  Moved: proxy/$_ -> ../claude-desktop-config/proxy/$_"
        }
    }

    # V6 archive
    @("server_v6.py", "config_v6.yaml") | ForEach-Object {
        $src = "$moveFrom\v6\$_"
        if (Test-Path $src) {
            Move-Item -Path $src -Destination "$moveTo\v6\$_" -Force
            Write-Output "  Moved: proxy/v6/$_ -> ../claude-desktop-config/proxy/v6/$_"
        }
    }

    # Logs
    @("proxy_debug.log", "proxy_audit.log", "proxy_stderr.log", "proxy_stdout.log") | ForEach-Object {
        $src = "$moveFrom\logs\$_"
        if (Test-Path $src) {
            Move-Item -Path $src -Destination "$moveTo\logs\$_" -Force
            Write-Output "  Moved: proxy/logs/$_ -> ../claude-desktop-config/proxy/logs/$_"
        }
    }

    # Memory notes
    @("proxy-cowork-integration.md", "proxy-history-and-thinking-issues.md", "proxy-vs-direct-self-observation.md") | ForEach-Object {
        $src = "$moveFrom\memory\$_"
        if (Test-Path $src) {
            Move-Item -Path $src -Destination "$moveTo\memory\$_" -Force
            Write-Output "  Moved: proxy/memory/$_ -> ../claude-desktop-config/proxy/memory/$_"
        }
    }

    # Remove empty proxy/ directory from bridge
    Remove-Item -Path $moveFrom -Recurse -Force
    Write-Output ""
    Write-Output "  Removed: bridge/proxy/ (empty, all moved)"
} else {
    Write-Output "SKIP: bridge/proxy/ does not exist"
}

# 3. Delete ROOT proxy files from bridge (the originals from git restore)
Write-Output ""
Write-Output "=== Cleaning up root-level proxy files from bridge ==="
$rootFiles = @(
    "proxy_server.py",
    "launch_proxy.py",
    "proxy_server_v6.py.archived",
    "config_v6.yaml.archived",
    "proxy_debug.log",
    "proxy_audit.log",
    "proxy_stderr.log",
    "proxy_stdout.log"
)

foreach ($f in $rootFiles) {
    $path = "$bridgeRoot\$f"
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
        Write-Output "  Deleted: $f"
    } else {
        Write-Output "  (not found): $f"
    }
}

# 4. Clean up reorg scripts from watcher/
Write-Output ""
Write-Output "=== Cleaning up temp scripts ==="
@("reorg_proxy.ps1", "restart_proxy.ps1") | ForEach-Object {
    $path = "$bridgeRoot\watcher\$_"
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
        Write-Output "  Deleted: watcher/$_"
    }
}

# 5. Clean up empty legacy dirs
Write-Output ""
Write-Output "=== Cleaning up empty legacy dirs ==="
@("backend-integration", "frontend-integration", "profile-system", "startup-scripts") | ForEach-Object {
    $path = "$bridgeRoot\$_"
    if (Test-Path $path) {
        $items = @(Get-ChildItem $path -Force)
        if ($items.Count -eq 0) {
            Remove-Item -Path $path -Force
            Write-Output "  Deleted: $_/ (empty)"
        } else {
            Write-Output "  Skipped: $_/ (has $($items.Count) items)"
        }
    }
}

# 6. Move config.yaml from bridge root IF it's the proxy config
# Check if bridge root config.yaml is proxy-related
$rootConfig = "$bridgeRoot\config.yaml"
if (Test-Path $rootConfig) {
    $content = Get-Content $rootConfig -Raw -ErrorAction SilentlyContinue
    if ($content -match "xiaomi|provider|anthropic|proxy") {
        # It's the proxy config, move it to the new proxy dir
        if (-not (Test-Path "$moveTo\config.yaml")) {
            Move-Item -Path $rootConfig -Destination "$moveTo\config.yaml" -Force
            Write-Output "  Moved: config.yaml -> claude-desktop-config/proxy/config.yaml"
        } else {
            Remove-Item -Path $rootConfig -Force
            Write-Output "  Deleted: config.yaml (already in config/proxy/)"
        }
    }
}

# 7. Move .env from bridge root IF it's proxy's .env
$rootEnv = "$bridgeRoot\.env"
if (Test-Path $rootEnv) {
    $content = Get-Content $rootEnv -Raw -ErrorAction SilentlyContinue
    if ($content -match "XIAOMI|API_KEY") {
        Remove-Item -Path $rootEnv -Force
        Write-Output "  Deleted: .env (proxy keys, now in config/proxy/.env)"
    }
}

# Done
Write-Output ""
Write-Output "=========================================="
Write-Output "Cleanup complete"
Write-Output "=========================================="
Write-Output ""
Write-Output "=== claude-desktop-config result ==="
Get-ChildItem "$configRoot" -Recurse -Name | Sort-Object | ForEach-Object { Write-Output "  $_" }
Write-Output ""
Write-Output "=== claude-bridge result ==="
Get-ChildItem "$bridgeRoot" -Directory -Name | Sort-Object | ForEach-Object { Write-Output "  $_/" }
Get-ChildItem "$bridgeRoot" -File -Name | Sort-Object | ForEach-Object { Write-Output "  $_" }
