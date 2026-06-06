# ══════════════════════════════════════════════════════════════════
# Common state + module imports — extracted from watcher.ps1 V22
# ══════════════════════════════════════════════════════════════════

# Module imports (BridgeCommon + BridgeExecution)
$modulesDir = Join-Path (Split-Path -Parent $script:baseDir) "modules"
Import-Module (Join-Path $modulesDir "BridgeCommon.psm1") -Force
Import-Module (Join-Path $modulesDir "BridgeExecution.psm1") -Force

# State variables
$script:lastCmdId = ""

# Self-upgrade tracking
$script:watcherScriptLastWrite = (Get-Item $script:watcherScriptPath).LastWriteTime
$script:watcherStartTime = Get-Date
$script:selfUpgradeCounter = 0
$script:selfUpgradeCheckInterval = 50
$script:restartFlagFile = Join-Path $script:baseDir ".graceful_restart"

# Housekeeping
$script:housekeepCounter = 0
$script:guardianCheckCounter = 0
$script:guardianTaskName = "BridgeGuardian-V3"
$script:registerGuardianScript = Join-Path (Split-Path -Parent $script:baseDir) "cluster\register_guardian_v3.ps1"

# Bridge agent + proxy health check paths
$script:agentScript = Join-Path (Split-Path -Parent $script:baseDir) "bridge_agent.py"
$script:agentPort = 19850
$script:restartProxyScript = Join-Path $script:baseDir "restart_proxy.ps1"

# V21 inflight tracking
$script:inflight = @{}

# Worker pool
$bridgeRoot = Split-Path -Parent $script:baseDir
$script:poolFile = Join-Path (Join-Path $bridgeRoot "cluster") ".worker_pool.json"
$script:pool = $null
$script:poolLastLoad = $null
$script:workerRR = @{}

# Rule engine (BridgeRules module)
Import-Module (Join-Path $modulesDir "BridgeRules.psm1") -Force
Init-RuleEngine -BridgeBase (Split-Path -Parent $script:baseDir)
Log "Rule engine loaded from BridgeRules.psm1"

# FileSystemWatcher — event-driven queue monitoring
$script:queueWatcher = New-Object System.IO.FileSystemWatcher
$script:queueWatcher.Path = $script:baseDir
$script:queueWatcher.Filter = "queue.txt"
$script:queueWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
Log "V22 FileSystemWatcher initialized — event-driven queue monitoring"
