$ErrorActionPreference = "Continue"
$clusterDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bridgeBase = Split-Path -Parent $clusterDir
& (Join-Path $clusterDir "worker_template.ps1") -WorkerName 'network_bridge' -BridgeBase $bridgeBase
