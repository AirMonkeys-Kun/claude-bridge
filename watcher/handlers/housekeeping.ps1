# ══════════════════════════════════════════════════════════════════
# Housekeeping handler — extracted from watcher.ps1 V22 (no logic change)
# ══════════════════════════════════════════════════════════════════

function Clean-HostLoopMode {
    $sessionDirs = @("$env:LOCALAPPDATA\Claude-3p\local-agent-mode-sessions")
    $found = 0; $fixed = 0
    foreach ($sd in $sessionDirs) {
        if (-not (Test-Path $sd)) { continue }
        try {
            Get-ChildItem "$sd\*\*\*\local_*\outputs\*.json" -ErrorAction SilentlyContinue | ForEach-Object {
                $found++
                try {
                    $content = [System.IO.File]::ReadAllText($_.FullName, $script:utf8)
                    if ($content -match '"hostLoopMode":\s*true') {
                        $content = $content -replace '"hostLoopMode":\s*true', '"hostLoopMode": false'
                        [System.IO.File]::WriteAllText($_.FullName, $content, $script:utf8)
                        $fixed++
                    }
                } catch {}
            }
        } catch {}
    }
    if ($fixed -gt 0) { Log "[HOUSEKEEP] Fixed hostLoopMode in $fixed session files (scanned $found)" }
}

function Assert-GuardianTask {
    $script:guardianCheckCounter++
    if ($script:guardianCheckCounter % 300 -ne 0) { return }

    try {
        $taskOutput = schtasks /Query /FO CSV /NH /TN "$script:guardianTaskName" 2>&1
        if ($LASTEXITCODE -eq 0 -and $taskOutput -match "$script:guardianTaskName") {
            Log "[GUARDIAN] Legacy task '$script:guardianTaskName' is still registered (no action taken)"
        }
    } catch {
        Log "[GUARDIAN] Legacy task '$script:guardianTaskName' not found — ok (self-managed)"
    }
}

function Invoke-Housekeeping {
    <#.SYNOPSIS Periodic cleanup tasks (~every 60s)#>
    param([int]$Counter)
    if ($Counter % 300 -eq 0) {
        Clean-HostLoopMode
        Assert-GuardianTask

        # Gap 1a: Archive old result files + rotated logs (replace delete with archive)
        try {
            Invoke-Archive -ResultAgeHours 1 -Purge
        } catch { Log "[HOUSEKEEP] Archive error: $($_.Exception.Message)" }

        # Rule engine: generate auto-rules from error history + prune stale rules
        try {
            $newRules = Generate-Rules
            if ($newRules -and $newRules.Count -gt 0) {
                Log "[HOUSEKEEP] Generated $($newRules.Count) auto-rules"
            }
            Update-Confidence
        } catch {
            Log "[HOUSEKEEP] Rule generation failed: $($_.Exception.Message)"
        }

        # Gap 2: bridge_agent + proxy health checks
        # ── Check bridge_agent (TCP :19850) ──
        try {
            $agentAlive = $false
            $agentCheck = Get-NetTCPConnection -LocalPort $script:agentPort -State Listen -ErrorAction SilentlyContinue
            if ($agentCheck) {
                $agentAlive = $true
            }

            if (-not $agentAlive -and (Test-Path $script:agentScript)) {
                Log "[HOUSEKEEP] BridgeAgent: DOWN — port $($script:agentPort) not listening, restarting..."
                $agentLogStdout = Join-Path $script:baseDir "bridge_agent_stdout.log"
                $agentLogStderr = Join-Path $script:baseDir "bridge_agent_stderr.log"
                $agentProc = Start-Process -FilePath "python.exe" `
                    -ArgumentList "`"$script:agentScript`"" `
                    -NoNewWindow -PassThru `
                    -RedirectStandardOutput $agentLogStdout `
                    -RedirectStandardError $agentLogStderr
                if ($agentProc) {
                    Log "  Launched bridge_agent PID=$($agentProc.Id)"
                    Start-Sleep -Seconds 2
                    $verify = Get-NetTCPConnection -LocalPort $script:agentPort -State Listen -ErrorAction SilentlyContinue
                    if ($verify) {
                        Log "  BridgeAgent restarted OK (pid=$($verify.OwningProcess))"
                    } else {
                        Log "  WARNING: BridgeAgent still not listening after restart"
                    }
                }
            } elseif (-not $agentAlive) {
                Log "[HOUSEKEEP] BridgeAgent: DOWN — script not found at $($script:agentScript) — skipping"
            }
        } catch {
            Log "[HOUSEKEEP] BridgeAgent check error: $($_.Exception.Message)"
        }

        # ── Check proxy (localhost:4000) ──
        try {
            $proxyAlive = $false
            $portCheck = Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue
            if ($portCheck) {
                $proxyAlive = $true
            }

            if (-not $proxyAlive) {
                Log "[HOUSEKEEP] Proxy: DOWN — port 4000 not listening, restarting..."
                if (Test-Path $script:restartProxyScript) {
                    try {
                        $result = & powershell -ExecutionPolicy Bypass -File $script:restartProxyScript 2>&1
                        Log "  Proxy restart result: $result"
                        Start-Sleep -Seconds 2
                        $verify = Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue
                        if ($verify) {
                            Log "  Proxy restarted OK (pid=$($verify.OwningProcess))"
                        } else {
                            Log "  WARNING: Proxy still not listening after restart"
                        }
                    } catch {
                        Log "  Proxy restart error: $($_.Exception.Message)"
                    }
                } else {
                    Log "  WARNING: restart_proxy.ps1 not found at $($script:restartProxyScript)"
                }
            }
        } catch {
            Log "[HOUSEKEEP] Proxy check error: $($_.Exception.Message)"
        }

        # Gap 3: Clean up legacy _bridge worker processes
        try {
            $legacyWorkers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
                $_.CommandLine -match "_(bridge)\\(?:worker|runner)\.ps1" -and
                $_.CommandLine -notmatch "user_bridge" -and
                $_.ProcessId -ne $PID
            }
            if ($legacyWorkers) {
                foreach ($w in $legacyWorkers) {
                    Log "[HOUSEKEEP] Killing legacy _bridge worker: PID=$($w.ProcessId) cmd=$($w.CommandLine.Substring(0, [Math]::Min(120, $w.CommandLine.Length)))"
                    try { Stop-Process -Id $w.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        } catch {
            Log "[HOUSEKEEP] Legacy worker cleanup error: $($_.Exception.Message)"
        }
    }
}
