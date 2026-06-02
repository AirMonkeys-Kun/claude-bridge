<#
.SYNOPSIS
    Claude Bridge Cluster — Worker 注册/启动/重启/状态管理脚本
.DESCRIPTION
    一键管理所有 6 个 worker 的 Scheduled Task。
    支持命令：register | start | stop | restart | status | cleanup

    用法：
        .\register-workers.ps1 register   # 注册/更新所有 Scheduled Tasks（需管理员）
        .\register-workers.ps1 start      # 启动所有 worker
        .\register-workers.ps1 stop       # 停止所有 worker
        .\register-workers.ps1 restart    # 重启所有 worker
        .\register-workers.ps1 status     # 查看所有 worker 状态
        .\register-workers.ps1 cleanup    # 清理过期结果文件
.PARAMETER Command
    要执行的命令（register | start | stop | restart | status | cleanup）
.PARAMETER BridgeBase
    claude-bridge 根目录。不指定则自动从脚本路径推断。
.PARAMETER WorkerName
    可选，只操作特定 worker（如 file_bridge）。不指定则操作全部 6 个。
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("register","start","stop","restart","status","cleanup")]
    [string]$Command = "status",

    [string]$BridgeBase = "",

    [string]$WorkerName = ""
)

# ── 自动检测 BridgeBase ──
if (-not $BridgeBase) {
    if ($PSScriptRoot) {
        $BridgeBase = Split-Path -Parent $PSScriptRoot  # cluster/ 的上一级
    } else {
        $BridgeBase = "D:\zebbingo\claude-bridge"
    }
}
$clusterDir = Join-Path $BridgeBase "cluster"

# ── Worker 列表 ──
$allWorkers = @(
    @{ name = "file_bridge";     desc = "文件操作" }
    @{ name = "registry_bridge"; desc = "注册表操作" }
    @{ name = "process_bridge";  desc = "进程管理" }
    @{ name = "network_bridge";  desc = "网络操作" }
    @{ name = "system_bridge";   desc = "系统服务" }
    @{ name = "wsl_bridge";      desc = "WSL/Linux" }
)

$workers = if ($WorkerName) { $allWorkers | Where-Object { $_.name -eq $WorkerName } } else { $allWorkers }

# ── 工具函数 ──
function Write-Color { param([string]$text, [string]$color="White")
    Write-Host $text -ForegroundColor $color
}

function Get-TaskName { param([string]$wn)
    return "BridgeCluster-$wn"
}

function Get-WorkerDir { param([string]$wn)
    return Join-Path $clusterDir $wn
}

# ── register：注册 Scheduled Tasks ──
function Invoke-Register {
    Write-Color "=== 注册 Worker Scheduled Tasks ===" "Cyan"
    $workerExe = "powershell.exe"
    $workerArgsFmt = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -WorkerName {1} -BridgeBase "{2}"'
    $templatePath = Join-Path $clusterDir "worker_template.ps1"

    if (-not (Test-Path $templatePath)) {
        Write-Color "错误：找不到 worker_template.ps1 于 $templatePath" "Red"
        return
    }

    foreach ($w in $workers) {
        $taskName = Get-TaskName -wn $w.name
        $fullArgs = $workerArgsFmt -f $templatePath, $w.name, $BridgeBase

        $action = New-ScheduledTaskAction -Execute $workerExe -Argument $fullArgs
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1)

        try {
            $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($existing) {
                Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings
                Write-Color "  ✅ $($w.name) — 已更新 ($taskName)" "Green"
            } else {
                Register-ScheduledTask `
                    -TaskName $taskName `
                    -Action $action `
                    -Trigger $trigger `
                    -Settings $settings `
                    -RunLevel Highest `
                    -Force
                Write-Color "  ✅ $($w.name) — 已注册 ($taskName)" "Green"
            }
        } catch {
            Write-Color "  ❌ $($w.name) — 注册失败: $_" "Red"
        }
    }

    Write-Color ""
    Write-Color "提示：部分操作需要管理员权限。如果注册失败，请以管理员身份运行。" "Yellow"
    Write-Color "启动所有 worker：Start-ScheduledTask -TaskName `"BridgeCluster-*`"" "Yellow"
}

# ── start：启动所有 worker ──
function Invoke-Start {
    Write-Color "=== 启动 Worker ===" "Cyan"
    foreach ($w in $workers) {
        $taskName = Get-TaskName -wn $w.name
        try {
            Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Write-Color "  ✅ $($w.name) — 启动信号已发送" "Green"
        } catch {
            Write-Color "  ⚠️  $($w.name) — 启动失败: $_" "Yellow"
        }
    }
}

# ── stop：停止所有 worker ──
function Invoke-Stop {
    Write-Color "=== 停止 Worker ===" "Cyan"
    Write-Color "注意：通过 taskkill 停止 worker，如 worker 处于 WaitForExit 可能延迟返回" "Yellow"
    foreach ($w in $workers) {
        $lockFile = Join-Path (Get-WorkerDir $w.name) ".watcher.lock"
        if (Test-Path $lockFile) {
            try {
                $pid = [int]([System.IO.File]::ReadAllText($lockFile, [System.Text.UTF8Encoding]::new($false)).Trim())
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                Write-Color "  ✅ $($w.name) — 已停止 (PID $pid)" "Green"
            } catch {
                Write-Color "  ⚠️  $($w.name) — 停止异常: $_" "Yellow"
            }
        } else {
            Write-Color "  ⚠️  $($w.name) — 没有 lock 文件，可能未运行" "Yellow"
        }
    }
}

# ── restart：重启所有 worker ──
function Invoke-Restart {
    Write-Color "=== 重启 Worker ===" "Cyan"
    Invoke-Stop
    Write-Color "等待 3 秒确保进程完全退出..." "Gray"
    Start-Sleep -Seconds 3
    Invoke-Start
    Write-Color ""
    Write-Color "等待 5 秒让 worker 启动..." "Gray"
    Start-Sleep -Seconds 5
    Invoke-Status
}

# ── status：查看状态 ──
function Invoke-Status {
    Write-Color "=== Worker 状态 ===" "Cyan"
    Write-Color ("{0,-20} {1,-8} {2,-22} {3,-10}" -f "Worker", "PID", "最后心跳", "状态")
    Write-Color ("{0,-20} {1,-8} {2,-22} {3,-10}" -f "──────", "───", "──────────", "──")
    $allAlive = $true
    foreach ($w in $allWorkers) {
        $dir = Get-WorkerDir $w.name
        $lockFile = Join-Path $dir ".watcher.lock"
        $hbFile = Join-Path $dir ".watcher_heartbeat"
        $pid = "—"
        $hb = "—"
        $status = "❌ 离线"

        if (Test-Path $lockFile) {
            try { $pid = [int]([System.IO.File]::ReadAllText($lockFile, [System.Text.UTF8Encoding]::new($false)).Trim()) } catch {}
        }
        if (Test-Path $hbFile) {
            try {
                $hb = [System.IO.File]::ReadAllText($hbFile, [System.Text.UTF8Encoding]::new($false)).Trim()
                $shortHb = if ($hb.Length -gt 19) { $hb.Substring(0, 19) } else { $hb }
                $hbTime = if ($shortHb -match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}') { [datetime]::ParseExact($matches[0], "yyyy-MM-dd HH:mm:ss", $null) } else { $null }
                if ($hbTime -and ((Get-Date) - $hbTime).TotalSeconds -lt 60) {
                    $status = "✅ 运行中"
                } else {
                    $status = "⚠️  可能离线"
                    $allAlive = $false
                }
            } catch { $status = "⚠️  异常" }
        }
        Write-Color ("{0,-20} {1,-8} {2,-22} {3,-10}" -f $w.name, $pid, $shortHb, $status) $(if ($status -match "✅") {"Green"} elseif ($status -match "⚠️") {"Yellow"} else {"Red"})
    }
    if ($allAlive) { Write-Color "所有 worker 运行正常" "Green" }
}

# ── cleanup：清理过期结果文件 ──
function Invoke-Cleanup {
    Write-Color "=== 清理过期结果文件 ===" "Cyan"
    $totalDeleted = 0
    $totalSize = 0
    $keepPatterns = @('^r_dl_cx_', '^r_install_cx_', '^r_vrf_', '^r_diag_', '^r_chk_dl_')

    foreach ($w in $allWorkers) {
        $dir = Get-WorkerDir $w.name
        if (-not (Test-Path $dir)) { continue }
        $files = Get-ChildItem -Path $dir -Filter "r_*.json"
        $deleted = 0
        $size = 0
        foreach ($f in $files) {
            $keep = $false
            foreach ($pattern in $keepPatterns) {
                if ($f.Name -match $pattern) { $keep = $true; break }
            }
            if (-not $keep) {
                $size += $f.Length
                Remove-Item -Path $f.FullName -Force
                $deleted++
            }
        }
        if ($deleted -gt 0) {
            Write-Color "  🗑️  $($w.name): 删除了 $deleted 个文件 ($([math]::Round($size/1KB,1)) KB)" "Gray"
            $totalDeleted += $deleted
            $totalSize += $size
        }
    }
    Write-Color "总计：删除了 $totalDeleted 个过期结果文件 ($([math]::Round($totalSize/1KB,1)) KB)" "Green"
}

# ── 执行 ──
switch ($Command) {
    "register" { Invoke-Register }
    "start"    { Invoke-Start }
    "stop"     { Invoke-Stop }
    "restart"  { Invoke-Restart }
    "status"   { Invoke-Status }
    "cleanup"  { Invoke-Cleanup }
    default    { Invoke-Status }
}
