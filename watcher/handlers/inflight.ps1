# ══════════════════════════════════════════════════════════════════
# Inflight tracking — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Add-Inflight { param([string]$CmdId, $Worker, [string]$Ctype, [string]$Cmd, [int]$Timeout)
    $script:inflight[$CmdId] = @{
        worker = $Worker
        ctype = $Ctype
        cmd = $Cmd
        start = Get-Date
        timeout = $Timeout
    }
    Log "[$CmdId] INFLIGHT added — $Ctype → $($Worker.id) (${Timeout}s timeout)"
}

function Remove-Inflight { param([string]$CmdId)
    $script:inflight.Remove($CmdId)
}

function Get-InflightCount { return $script:inflight.Count }

function Check-InflightResults {
    $completed = 0
    $toRemove = @()

    foreach ($cid in $script:inflight.Keys) {
        try {
            $info = $script:inflight[$cid]
            $elapsed = [int]((Get-Date) - $info.start).TotalSeconds

            if ($elapsed -gt ($info.timeout + 5)) {
                Log "[$cid] INFLIGHT TIMEOUT after ${elapsed}s (>$($info.timeout)s)"
                $toRemove += $cid
                $completed++
                continue
            }

            $rFile = Join-Path $script:baseDir "r_${cid}.json"
            if (Test-Path $rFile) {
                $content = Read-Json -path $rFile
                if ($content) {
                    Log "[$cid] INFLIGHT COMPLETE — exit=$($content.exit_code) dur=$($content.duration_ms)ms"
                    try {
                        Log-ExecutionError -CmdId $cid -Type $info.ctype -Command $info.cmd `
                            -ExitCode $content.exit_code -StdoutText $content.stdout `
                            -StderrText $content.stderr -DurationMs $content.duration_ms
                    } catch {
                        Log "[$cid] Error learning failed: $($_.Exception.Message)"
                    }
                }
            }
        } catch {
            Log "[$cid] INFLIGHT processing error: $($_.Exception.Message) — force-removing"
        }
        if ($cid -notin $toRemove) { $toRemove += $cid; $completed++ }
    }

    foreach ($cid in $toRemove) {
        $script:inflight.Remove($cid)
    }

    return $completed
}
