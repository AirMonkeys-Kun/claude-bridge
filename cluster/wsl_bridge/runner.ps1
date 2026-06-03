$ErrorActionPreference = "Continue"
$clusterDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$wslDir = Join-Path $clusterDir "wsl_bridge"
# 使用 V4 增强版 WSL Worker（支持 Named Pipe IPC + 后台文件监视器 + 内联执行优化）
# 而非通用 worker_template.ps1
& (Join-Path $wslDir "worker.ps1") -WorkerDir $wslDir
