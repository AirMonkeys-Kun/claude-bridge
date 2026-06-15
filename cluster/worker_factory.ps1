#Requires -Version 5.0
<#
 worker_factory.ps1 — Typed worker factory (V2.2)
 ────────────────
 Creates workers by TYPE with configurable concurrency counts.
 Each worker runs worker_generic.ps1 with a typed identity.

 V2.2: -DeployAll mode — creates ALL worker types in ONE call with atomic pool write.
       Eliminates pool race condition from per-type sequential calls (file_1 missing bug).
 V2.1: .NET Process.Start instead of Start-Process for non-interactive contexts
       WriteAllText instead of Out-File for pool file (no locking issues)
       (register_guardian_v3.ps1: $ErrorActionPreference = "Continue" fix)

 Usage:
   .\worker_factory.ps1 -DeployAll -BridgeBase D:\...   # RECOMMENDED: all 14 workers, one atomic pool write
   .\worker_factory.ps1 -KillAll                          # Kill ALL workers, clear pool
   .\worker_factory.ps1 -Type generic -Count 4             # Create 4 generic workers
   .\worker_factory.ps1 -List                              # Show current pool summary

 DeployAll plan:
   generic ×4, file ×4, process ×2, system ×2, wsl ×1, user ×1 = 14 total

 Worker naming: {type}_{n} (e.g., file_1, file_2)
 Pipe naming:   Cluster_Wkr_{type}_{n} (e.g., Cluster_Wkr_file_1)
 Directory:     cluster/{type}_{n}/ (e.g., cluster/file_1/)
 Pool file:     cluster/.worker_pool.json (unified, all types)
#>

param(
    [string]$Type = "",
    [int]$Count = 0,
    [string]$BridgeBase = "",
    [switch]$KillAll,
    [switch]$List,
    [switch]$DeployAll,
    [switch]$FromConfig
)

if (-not $BridgeBase) {
    $BridgeBase = Split-Path -Parent $MyInvocation.MyCommand.Path
    $BridgeBase = Split-Path -Parent $BridgeBase  # go up from cluster/
}

$clusterDir = Join-Path $BridgeBase "cluster"
$workerScript = Join-Path $clusterDir "worker_generic.ps1"
$poolFile = Join-Path $clusterDir ".worker_pool.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Log($m) { Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') | [FACTORY] $m" }

# ── Read pool helper ──
function Read-Pool {
    if (Test-Path $poolFile) {
        try { return Get-Content $poolFile -Raw | ConvertFrom-Json } catch {}
    }
    return $null
}

function Write-Pool($pool) {
    $json = $pool | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($poolFile, $json, $utf8NoBom)
}

# ── List mode ──
if ($List) {
    $pool = Read-Pool
    if (-not $pool -or -not $pool.workers -or $pool.workers.Count -eq 0) {
        Log "Pool is empty"
        return
    }
    Log "=== Worker Pool ==="
    $typeGroups = $pool.workers | Group-Object type
    foreach ($g in $typeGroups) {
        $alive = 0
        foreach ($w in $g.Group) {
            if (Get-Process -Id $w.pid -ErrorAction SilentlyContinue) { $alive++ }
        }
        Log "  $($g.Name): $alive/$($g.Count) alive — $($g.Group.id -join ', ')"
    }
    Log "Total: $($pool.workers.Count) workers"
    return
}

# ── KillAll mode ──
if ($KillAll) {
    Log "=== KillAll ==="
    $pool = Read-Pool
    if ($pool -and $pool.workers) {
        foreach ($w in $pool.workers) {
            try {
                Stop-Process -Id $w.pid -Force -ErrorAction SilentlyContinue
                Log "  Killed $($w.id) PID=$($w.pid)"
            } catch {}
        }
    }
    Remove-Item $poolFile -Force -ErrorAction SilentlyContinue
    # Also kill any orphaned typed workers
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -like "*worker_generic*"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        Log "  Killed orphaned worker PID=$($_.ProcessId)"
    }
    Log "Pool cleared"
    return
}

# ── DeployAll mode ──
if ($DeployAll) {
    Log "=== DeployAll: creating 14 workers across 6 types, atomic pool write ==="

    # Read config if -FromConfig specified
    $configFile = Join-Path $clusterDir "worker-config.json"
    if ($FromConfig -and (Test-Path $configFile)) {
        Log "Reading deploy plan from $configFile"
        $config = Get-Content $configFile -Raw | ConvertFrom-Json
        $deployPlan = @()
        foreach ($item in $config.deploy_plan) {
            $deployPlan += @{type=$item.type; count=$item.count; pipe_prefix=$item.pipe_prefix}
        }
        Log "  Loaded $($deployPlan.Count) types from config"
    } else {
        # Hardcoded fallback (original behavior)
        Log "Using hardcoded deploy plan (use -FromConfig to read worker-config.json)"
        $deployPlan = @(
            @{type="generic"; count=6},
            @{type="file"; count=4},
            @{type="process"; count=2},
            @{type="system"; count=2},
            @{type="user"; count=1}
        )
    }

    $allWorkers = @()

    foreach ($plan in $deployPlan) {
        $t = $plan.type; $c = $plan.count
        Log "  Creating $c '$t' worker(s)..."
        for ($i = 1; $i -le $c; $i++) {
            $wid = "${t}_${i}"
            $workerDir = Join-Path $clusterDir "${t}_${i}"
            New-Item -Path $workerDir -ItemType Directory -Force | Out-Null

            # Init queue file (WriteAllText — no locking issues)
            $qFile = Join-Path $workerDir "queue.txt"
            [System.IO.File]::WriteAllText($qFile, '{"state":"idle","cmd_id":"","command":"","type":""}', $utf8NoBom)

            # Launch worker
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "powershell.exe"
                $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$workerScript`" -WorkerId $wid -Type $t -BridgeBase `"$BridgeBase`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $null = $p.BeginOutputReadLine()
                $null = $p.BeginErrorReadLine()

                $allWorkers += @{
                    id = $wid
                    type = $t
                    pid = $p.Id
                    pipe = "Cluster_Wkr_${t}_${i}"
                    queue = "cluster\${t}_${i}\queue.txt"
                    started = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                Log "    $wid : PID=$($p.Id) PIPE=Cluster_Wkr_${t}_${i}"
            } catch {
                Log "    $wid : FAILED — $_"
            }
        }
    }

    # ── Wait for heartbeats (single wait for ALL workers) ──
    Log "Waiting for heartbeats (4s)..."
    Start-Sleep -Seconds 4

    $aliveCount = 0
    foreach ($w in $allWorkers) {
        $hbFile = Join-Path $clusterDir "$($w.id)\.heartbeat"
        if (Test-Path $hbFile) {
            $hb = Get-Content $hbFile -Raw -ErrorAction SilentlyContinue
            $aliveCount++
            Log "  $($w.id) : ALIVE — HB=$($hb.Trim())"
        } else {
            Log "  $($w.id) : NO HEARTBEAT (may still be starting)"
        }
    }

    # ── Single atomic pool write ──
    $pool = @{
        version = "2.2"
        created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        workers = $allWorkers
    }
    Write-Pool $pool
    Log "=== Pool written atomically: $aliveCount/$($allWorkers.Count) workers alive ==="
    return
}

# ── Validate type and count ──
if (-not $Type) {
    Log "ERROR: -Type required (generic, file, process, system, wsl, user)"
    exit 1
}
if ($Count -le 0) {
    Log "ERROR: -Count must be > 0"
    exit 1
}

# ── Create typed workers ──
Log "=== Creating $Count '$Type' workers ==="
$pool = Read-Pool
if (-not $pool) {
    $pool = @{ version = "2.0"; created = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); workers = @() }
}

# Kill existing workers of THIS type (for restart/replace)
$existingOfType = @($pool.workers | Where-Object { $_.type -eq $Type })
foreach ($w in $existingOfType) {
    try {
        Stop-Process -Id $w.pid -Force -ErrorAction SilentlyContinue
        Log "  Killed existing $($w.id) PID=$($w.pid)"
    } catch {}
}
$pool.workers = @($pool.workers | Where-Object { $_.type -ne $Type })

# Create new workers
$workers = @()
for ($i = 1; $i -le $Count; $i++) {
    $wid = "${Type}_${i}"
    $workerDir = Join-Path $clusterDir "$Type`_$i"
    New-Item -Path $workerDir -ItemType Directory -Force | Out-Null

    # Init queue file (WriteAllText — no locking issues)
    $queueFile = Join-Path $workerDir "queue.txt"
    [System.IO.File]::WriteAllText($queueFile, '{"state":"idle","cmd_id":"","command":"","type":""}', $utf8NoBom)

    # Launch worker (V2.1: .NET Process.Start — works in non-interactive contexts)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$workerScript`" -WorkerId $wid -Type $Type -BridgeBase `"$BridgeBase`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # BeginOutput/ErrorReadLine to avoid deadlock (we don't read the output)
        $null = $p.BeginOutputReadLine()
        $null = $p.BeginErrorReadLine()

        $workers += @{
            id = $wid
            type = $Type
            pid = $p.Id
            pipe = "Cluster_Wkr_${Type}_${i}"
            queue = "cluster\${Type}_${i}\queue.txt"
            started = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        Log "  $wid : PID=$($p.Id) PIPE=Cluster_Wkr_${Type}_${i}"
    } catch {
        Log "  $wid : FAILED — $_"
    }
}

# ── Wait for heartbeats ──
Log "Waiting for heartbeats..."
Start-Sleep -Seconds 3

$alive = 0
foreach ($w in $workers) {
    $correctHb = Join-Path $clusterDir "$($w.id)\.heartbeat"
    if (Test-Path $correctHb) {
        $hb = Get-Content $correctHb -Raw -ErrorAction SilentlyContinue
        $alive++
        Log "  $($w.id) : ALIVE — HB=$($hb.Trim())"
    } else {
        Log "  $($w.id) : NO HEARTBEAT (may still be starting)"
    }
}

# ── Merge into pool ──
$pool.workers += $workers
$pool | Add-Member -NotePropertyName "updated" -NotePropertyValue (Get-Date -Format "yyyy-MM-dd HH:mm:ss") -Force
Write-Pool $pool

Log "=== $alive/$Count '$Type' workers alive ==="
$totalWorkers = $pool.workers.Count
$totalAlive = 0
foreach ($w in $pool.workers) {
    if (Get-Process -Id $w.pid -ErrorAction SilentlyContinue) { $totalAlive++ }
}
Log "Pool total: $totalAlive/$totalWorkers workers across types"
