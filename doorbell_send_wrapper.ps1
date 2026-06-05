# doorbell_send_wrapper.ps1
# Wrapper: writes to bridge queue AND sends vsock doorbell for instant notification
#
# Usage: .\doorbell_send_wrapper.ps1 [-QueueFile <path>] [-Command <json>]
#   or pipe JSON to it: echo '{"cmd_id":"test",...}' | .\doorbell_send_wrapper.ps1
#
# Architecture:
#   1. Write command to bridge queue (existing 9P mechanism)
#   2. Ring vsock doorbell → daemon → Unix socket → sandbox listener
#   3. Sandbox listener busts FUSE cache → instant stat() → bridge picks up
#
# Without doorbell: 200-600ms FUSE cache delay
# With doorbell: ~2-3ms total latency

param(
    [string]$QueueFile = "D:\zebbingo\tools\claude-bridge\cluster\.pipe_master_queue.json",
    [string]$DoorbellScript = "D:\zebbingo\tools\claude-bridge\send_vsock_doorbell.ps1",
    [string]$VmGuid = "",
    [switch]$SkipDoorbell
)

$startTime = Get-Date

# 1. Read JSON from stdin or param
$commandJson = $input | Out-String
if (-not $commandJson.Trim()) {
    $commandJson = $Command
}

if (-not $commandJson.Trim()) {
    Write-Error "No command JSON provided"
    exit 1
}

# 2. Write to queue file
$writeStart = Get-Date
$commandJson.Trim() | Out-File -FilePath $QueueFile -Encoding utf8 -NoNewline
$writeMs = [int]((Get-Date) - $writeStart).TotalMilliseconds

Write-Host "[doorbell-wrapper] Queue write: ${writeMs}ms"

# 3. Ring doorbell (if available)
$doorbellMs = 0
$doorbellResult = "skipped"

if (-not $SkipDoorbell) {
    if (Test-Path $DoorbellScript) {
        $dbStart = Get-Date
        try {
            $args = @("-File", $DoorbellScript)
            if ($VmGuid) { $args += "-VmGuid"; $args += $VmGuid }
            $result = & powershell -NoProfile -ExecutionPolicy Bypass @args 2>&1
            $doorbellMs = [int]((Get-Date) - $dbStart).TotalMilliseconds
            $doorbellResult = if ($LASTEXITCODE -eq 0) { "sent" } else { "failed: $result" }
        } catch {
            $doorbellMs = [int]((Get-Date) - $dbStart).TotalMilliseconds
            $doorbellResult = "error: $_"
        }
    } else {
        $doorbellResult = "no-sender (VM GUID needed)"
    }
}

$totalMs = [int]((Get-Date) - $startTime).TotalMilliseconds

Write-Host "[doorbell-wrapper] Doorbell: $doorbellResult (${doorbellMs}ms)"
Write-Host "[doorbell-wrapper] Total: ${totalMs}ms (write:${writeMs}ms + doorbell:${doorbellMs}ms)"
Write-Output "OK total=${totalMs}ms write=${writeMs}ms doorbell=${doorbellResult}"

exit 0
