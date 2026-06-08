# Clean up extra bridge_agent instances, keep the one serving port 19850
$ErrorActionPreference = 'SilentlyContinue'

Write-Output "=== Scanning bridge_agent instances ==="

# Get all python processes running bridge_agent.py
$agents = Get-Process python -ErrorAction SilentlyContinue | Where-Object {
    $cmd = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" | Select-Object -ExpandProperty CommandLine
    $cmd -match 'bridge_agent\.py'
}

Write-Output ("Found " + $agents.Count + " bridge_agent processes")

# Get processes listening on port 19850
$listeners = netstat -ano | Select-String ':19850 ' | Select-String 'LISTENING'
$listenerPids = @()
foreach ($line in $listeners) {
    $parts = $line -split '\s+'
    $pid = [int]$parts[-1]
    if ($pid -gt 0 -and $listenerPids -notcontains $pid) {
        $listenerPids += $pid
    }
}

Write-Output ("PIDs listening on 19850: " + ($listenerPids -join ','))

# Pick the first PID as the one to keep
if ($listenerPids.Count -gt 0) {
    $keepPid = $listenerPids[0]
    Write-Output ("Keeping PID " + $keepPid)

    # Kill all other bridge_agent processes
    foreach ($agent in $agents) {
        if ($agent.Id -ne $keepPid) {
            Stop-Process -Id $agent.Id -Force
            Write-Output ("Killed bridge_agent PID " + $agent.Id)
        }
    }

    # Also kill any listener PIDs that aren't in agents list
    foreach ($pid in $listenerPids) {
        if ($pid -ne $keepPid) {
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -eq 'python') {
                Stop-Process -Id $pid -Force
                Write-Output ("Killed orphan listener PID " + $pid)
            }
        }
    }
} else {
    Write-Output "No bridge_agent listeners found on port 19850"
}

# Final count
$remaining = Get-Process python -ErrorAction SilentlyContinue | Where-Object {
    $cmd = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" | Select-Object -ExpandProperty CommandLine
    $cmd -match 'bridge_agent\.py'
}
Write-Output ("Remaining bridge_agent: " + $remaining.Count)

# Verify port 19850 is still listening
$stillUp = netstat -ano | Select-String ':19850 ' | Select-String 'LISTENING'
if ($stillUp) {
    Write-Output "Port 19850: LISTENING"
} else {
    Write-Output "WARNING: Port 19850 is DOWN - need to restart bridge_agent"
}

Write-Output "=== Done ==="
