#Requires -Version 5.0
<#
.SYNOPSIS
    Bridge Relay — syncs root D:\zebbingo\queue.txt ↔ watcher/queue.txt
.DESCRIPTION
    Monitors the root queue.txt (public-facing entry point) and forwards
    pending commands to the watcher's internal queue.txt for execution.
    Also copies results back to root directory.
#>

$ErrorActionPreference = "Continue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$rootQueue = "D:\zebbingo\queue.txt"
$watcherQueue = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "watcher\queue.txt"
$watcherDir = Split-Path -Parent $watcherQueue
$relayLog = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "watcher\relay.log"

function RLog($m) {
    $t = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
    try { [System.IO.File]::AppendAllText($relayLog, "$t | [RELAY] $m`r`n", $utf8) } catch {}
}

function Read-Json($path) {
    if (-not (Test-Path $path)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $text = [System.IO.File]::ReadAllText($path, $utf8)
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 30 }
    }
}

function Write-Json($path, $obj) {
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $json = $obj | ConvertTo-Json -Compress
            [System.IO.File]::WriteAllText($path, $json, $utf8)
            return $true
        } catch { if ($i -eq 2) { return $false }; Start-Sleep -Milliseconds 30 }
    }
}

$idleRoot = @{state="idle"; cmd_id=""; command=""; type=""}
$lastForwarded = ""

RLog "Relay started — root=$rootQueue, watcher=$watcherQueue"

while ($true) {
    $rootCmd = Read-Json $rootQueue
    if ($rootCmd -and $rootCmd.state -eq "pending" -and $rootCmd.cmd_id -ne "" -and $rootCmd.cmd_id -ne $lastForwarded) {
        $lastForwarded = $rootCmd.cmd_id
        RLog "Forwarding cmd_id=$($rootCmd.cmd_id) type=$($rootCmd.type)"

        # Write to watcher queue
        if (Write-Json $watcherQueue @{
            state = "pending"
            cmd_id = $rootCmd.cmd_id
            command = $rootCmd.command
            type = $rootCmd.type
            timeout = if ($rootCmd.timeout -gt 0) { $rootCmd.timeout } else { 30 }
        }) {
            RLog "Forwarded $($rootCmd.cmd_id)"
            # Reset root queue to idle so caller knows it was picked up
            Write-Json $rootQueue $idleRoot
        } else {
            RLog "FAILED to forward $($rootCmd.cmd_id)"
        }
    }

    # Check for results from watcher and copy to root
    $resultFile = Join-Path $watcherDir "r_$($lastForwarded).json"
    if ($lastForwarded -ne "" -and (Test-Path $resultFile)) {
        $destFile = "D:\zebbingo\r_$($lastForwarded).json"
        try {
            Copy-Item $resultFile $destFile -Force -ErrorAction SilentlyContinue
        } catch {}
    }

    Start-Sleep -Milliseconds 500
}
