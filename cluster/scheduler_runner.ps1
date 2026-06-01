$ErrorActionPreference = "Continue"
# master_scheduler.ps1 auto-detects BridgeBase from its own $PSScriptRoot
& (Join-Path $PSScriptRoot "master_scheduler.ps1")
