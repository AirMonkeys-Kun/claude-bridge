# ══════════════════════════════════════════════════════════════════
# Common state — extracted from watcher.ps1 V22
#
# NOTE: Module imports (BridgeCommon, BridgeExecution, BridgeRules)
# are in watcher.ps1, NOT here. Import-Module -Force in a dot-sourced
# file removes and re-adds modules, which breaks function bindings
# established by earlier dot-sourced files (e.g. Log in logging.ps1).
# ══════════════════════════════════════════════════════════════════

# State variables
$script:lastCmdId = ""

# Self-upgrade tracking
$script:watcherScriptLastWrite = (Get-Item $script:watcherScriptPath).LastWriteTime
$script:watcherScriptHash = (Get-FileHash $script:watcherScriptPath).Hash
$script:watcherStartTime = Get-Date
$script:selfUpgradeCounter = 0
$script:selfUpgradeCheckInterval = 50
$script:selfUpgradeCooldown = 60            # Min seconds between self-upgrade restarts
$script:selfUpgradeLastTrigger = $null      # Timestamp of last triggered restart
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

# Rule engine — Init (import is in watcher.ps1)

# FileSystemWatcher — event-driven queue monitoring
$script:queueWatcher = New-Object System.IO.FileSystemWatcher
$script:queueWatcher.Path = $script:baseDir
$script:queueWatcher.Filter = "queue.txt"
$script:queueWatcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
Log "V22 FileSystemWatcher initialized — event-driven queue monitoring"

# Named Mutex — cross-process singleton guard (V22.1, replaces unreliable PID lock)
# Auto-released on process exit/crash. Prevents multi-watcher cascades.
$script:watcherMutexName = "Global\ClaudeBridgeWatcher_V2"
$script:watcherMutex = New-Object System.Threading.Mutex($false, $script:watcherMutexName)
