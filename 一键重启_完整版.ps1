<#
.SYNOPSIS
    Claude Bridge 完整重启脚本 — V20: 工厂按类型创建 workers
.DESCRIPTION
    V20 (2026-06-04):
    - 重构: worker_factory 按类型 (generic×4, file×4, process×2, system×2, wsl×1, user×1) 创建 workers
    - 融合: 并发能力 + 专业化能力 — 每个类型多个 worker，可并发执行
    - 移除: pipe_daemon.ps1 (已融入 watcher，watcher 通过 Named Pipe 分发到 typed workers)
    - 移除: .pipe_master_queue.json (不再需要独立 daemon)
    - 保留: worker_factory 管理所有 worker 生命周期
    - 保留: watcher 管理命令解析、规则引擎、结果写入
    用法：以管理员身份运行此脚本
#>

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$clusterDir = Join-Path $root "cluster"
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Log($m) {
    $t = (Get-Date).ToString("HH:mm:ss.fff")
    Write-Host "$t | $m"
}

# ── Step 1: Kill all old processes ──
Log "=== Step 1: Killing old processes ==="

# Kill pipe daemon (if any still running)
$lockFile = Join-Path $clusterDir ".pipe_daemon.lock"
if (Test-Path $lockFile) {
    try {
        $pid = [int]([System.IO.File]::ReadAllText($lockFile, $utf8).Trim())
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
        Log "Killed pipe daemon PID=$pid"
    } catch { Log "Could not read daemon lock" }
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}

# Kill all generic/typed worker processes
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -like "*worker_generic*"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Log "Killed generic worker PID=$($_.ProcessId)"
}

# Kill pipe daemon by name (stale processes)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -like "*pipe_daemon*"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Log "Killed pipe daemon (by name) PID=$($_.ProcessId)"
}

# Kill watchers
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
    $_.CommandLine -like "*watcher*ps1*"
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Log "Killed watcher PID=$($_.ProcessId)"
}

# NOTE: old domain workers (file_bridge/process_bridge/etc. via Scheduled Tasks) are NOT killed.
# They coexist with the new typed workers. Old domain workers operate via their own queue.txt files;
# new typed workers are used by the watcher's V19 Named Pipe dispatch.

Start-Sleep 2

# ── Step 2: Clean up stale files ──
Log "=== Step 2: Cleaning up stale files ==="
@(
    ".pipe_master_queue.json", ".pipe_batch_result.json", ".pipe_daemon.lock",
    ".pipe_daemon.heartbeat", ".worker_pool.json"
) | ForEach-Object {
    $f = Join-Path $clusterDir $_
    if (Test-Path $f) { Remove-Item $f -Force; Log "Removed $_" }
}

# Clean up old result files (keep last 50)
$resultDir = Join-Path $root "watcher"
if (Test-Path $resultDir) {
    $oldResults = Get-ChildItem (Join-Path $resultDir "r_*.json") | Sort-Object LastWriteTime -Descending | Select-Object -Skip 50
    if ($oldResults) { $oldResults | Remove-Item -Force; Log "Cleaned $($oldResults.Count) old result files" }
}

# ── Step 3: KillAll via factory (clear pool + kill orphans) ──
Log "=== Step 3: KillAll workers via factory ==="
$factoryScript = Join-Path $clusterDir "worker_factory.ps1"
& $factoryScript -KillAll -BridgeBase $root
Log "All workers killed"

# ── Step 4: Create typed workers via factory ──
Log "=== Step 4: Creating typed workers ==="
# Concurrency: most-used types get 4 workers, less-used get 2 or 1
$typeConfig = @(
    @{ type = "generic"; count = 4 }
    @{ type = "file";    count = 4 }
    @{ type = "process"; count = 2 }
    @{ type = "system";  count = 2 }
    @{ type = "wsl";     count = 1 }
    @{ type = "user";    count = 1 }
)

$totalExpected = 0
foreach ($tc in $typeConfig) {
    & $factoryScript -Type $tc.type -Count $tc.count -BridgeBase $root
    $totalExpected += $tc.count
}

# Verify pool was created
$poolFile = Join-Path $clusterDir ".worker_pool.json"
if (-not (Test-Path $poolFile)) {
    Log "FATAL: worker_factory did not create pool file"
    exit 1
}

$pool = Get-Content $poolFile -Raw | ConvertFrom-Json
$typeNames = @($pool.workers.type | Select-Object -Unique)
Log "Pool created: $($pool.workers.Count) workers across $($typeNames -join ', ') types"

# ── Step 5: Verify workers ──
Log "=== Step 5: Verifying workers ==="
Start-Sleep 2
$aliveCount = 0
$aliveWorkers = @()
foreach ($w in $pool.workers) {
    $pipeName = $w.pipe
    try {
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $pipe.Connect(2000)
        $pipe.Close()
        Log "  $($w.id) ($pipeName): PIPE OK"
        $aliveCount++
        $aliveWorkers += $w.id
    } catch {
        Log "  $($w.id) ($pipeName): NOT RESPONDING"
    }
}
Log "Workers responsive: $aliveCount / $($pool.workers.Count)"
Log "Active: $($aliveWorkers -join ', ')"

# ── Step 6: Done ──
Log "=== Restart complete ==="
Log "Pool: $($pool.workers.Count) workers ($($pool.workers.id -join ', '))"
Log "Watcher will dispatch commands to typed workers via Named Pipe"
Log ""
Log "Watcher queue: watcher\queue.txt"
Log "Result files: watcher\r_{cmd_id}.json"
