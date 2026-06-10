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

    # ── Proxy restart backoff (V22.1) — lazy init on first call ──
    if (-not $script:proxyRestartState) {
        $script:proxyRestartState = @{
            failCount = 0
            lastAttempt = $null
            suppressedUntil = $null
            lastKnownAlive = $null
        }
    }

    if ($Counter % 300 -eq 0) {
        # Dedup store cleanup (expire old entries)
        try { Invoke-ContentDedupCleanup } catch { Log "[HOUSEKEEP] ContentDedup cleanup error: $($_.Exception.Message)" }

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
        # ── Bridge agent backoff state (V22.1) ──
        if (-not $script:bridgeAgentBackoff) {
            $script:bridgeAgentBackoff = @{ failCount = 0; suppressedUntil = $null }
        }

        # ── Check bridge_agent (TCP :19850) with backoff ──
        try {
            $now = Get-Date
            $agentShouldCheck = $true
            if ($script:bridgeAgentBackoff.suppressedUntil -and $now -lt $script:bridgeAgentBackoff.suppressedUntil) { $agentShouldCheck = $false }

            if ($agentShouldCheck) {
            $agentAlive = $false
            $agentCheck = Get-NetTCPConnection -LocalPort $script:agentPort -State Listen -ErrorAction SilentlyContinue
            if ($agentCheck) {
                $agentAlive = $true
            }

            if (-not $agentAlive -and (Test-Path $script:agentScript)) {
                $script:bridgeAgentBackoff.failCount++
                if ($script:bridgeAgentBackoff.failCount -ge 10) {
                    $script:bridgeAgentBackoff.suppressedUntil = $now.AddMinutes(15)
                    Log "[HOUSEKEEP] BridgeAgent restart failed $($script:bridgeAgentBackoff.failCount) times — suppressing for 15min"
                } elseif ($script:bridgeAgentBackoff.failCount -ge 5) {
                    $script:bridgeAgentBackoff.suppressedUntil = $now.AddMinutes(2)
                    Log "[HOUSEKEEP] BridgeAgent restart failed $($script:bridgeAgentBackoff.failCount) times — suppressing for 2min"
                }

                Log "[HOUSEKEEP] BridgeAgent: DOWN — port $($script:agentPort) not listening (failure #$($script:bridgeAgentBackoff.failCount)), restarting..."
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
                        $script:bridgeAgentBackoff.failCount = 0
                    } else {
                        Log "  WARNING: BridgeAgent still not listening after restart"
                    }
                }
            } elseif (-not $agentAlive) {
                Log "[HOUSEKEEP] BridgeAgent: DOWN — script not found at $($script:agentScript) — skipping"
            } else {
                # Agent is alive — reset failure count
                $script:bridgeAgentBackoff.failCount = 0
            }
            }  # end if ($agentShouldCheck)
        } catch {
            Log "[HOUSEKEEP] BridgeAgent check error: $($_.Exception.Message)"
        }

        # ── Check proxy (localhost:4000) with backoff (V22.1) ──
        try {
            $now = Get-Date
            $proxyShouldCheck = $true
            # Skip if suppressed (repeated failures → backoff)
            if ($script:proxyRestartState.suppressedUntil -and $now -lt $script:proxyRestartState.suppressedUntil) {
                $proxyShouldCheck = $false
            }

            if ($proxyShouldCheck) {
            $proxyAlive = $false
            $portCheck = Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue
            if ($portCheck) {
                $proxyAlive = $true
            }

            if ($proxyAlive) {
                # Reset failure count on success
                if ($script:proxyRestartState.failCount -gt 0) {
                    $script:proxyRestartState.failCount = 0
                    Log "[HOUSEKEEP] Proxy back on port 4000 — reset failure count"
                }
                $script:proxyRestartState.lastKnownAlive = $now
            } else {
                $script:proxyRestartState.failCount++
                $script:proxyRestartState.lastAttempt = $now

                if ($script:proxyRestartState.failCount -ge 20) {
                    # Repeated failures → suppress for 30min
                    $script:proxyRestartState.suppressedUntil = $now.AddMinutes(30)
                    Log "[HOUSEKEEP] Proxy restart failed $($script:proxyRestartState.failCount) times — suppressing for 30min"
                } elseif ($script:proxyRestartState.failCount -ge 10) {
                    # Medium backoff: 5min
                    $script:proxyRestartState.suppressedUntil = $now.AddMinutes(5)
                    Log "[HOUSEKEEP] Proxy restart failed $($script:proxyRestartState.failCount) times — suppressing for 5min"
                } elseif ($script:proxyRestartState.failCount -ge 5) {
                    # Short backoff: 60s
                    $script:proxyRestartState.suppressedUntil = $now.AddSeconds(60)
                    Log "[HOUSEKEEP] Proxy restart failed $($script:proxyRestartState.failCount) times — suppressing for 60s"
                }

                Log "[HOUSEKEEP] Proxy: DOWN — port 4000 not listening (failure #$($script:proxyRestartState.failCount)), restarting..."
                if (Test-Path $script:restartProxyScript) {
                    try {
                        $result = & powershell -ExecutionPolicy Bypass -File $script:restartProxyScript 2>&1
                        Log "  Proxy restart result: $result"
                        Start-Sleep -Seconds 2
                        $verify = Get-NetTCPConnection -LocalPort 4000 -State Listen -ErrorAction SilentlyContinue
                        if ($verify) {
                            Log "  Proxy restarted OK (pid=$($verify.OwningProcess))"
                            $script:proxyRestartState.failCount = 0
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
            }  # end if ($proxyShouldCheck)
        } catch {
            Log "[HOOKEEP] Proxy check error: $($_.Exception.Message)"
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

        # Gap 4: Periodic worker pool sync (V2.3) — every ~300 loops = ~60s
        try {
            Sync-WorkerPool
        } catch {
            Log "[HOUSEKEEP] Pool sync error: $($_.Exception.Message)"
        }

        # Gap 5: Clean up stale .watcher.lock (V22.1 — migrated to Mutex, clean up old files)
        try {
            $oldLock = Join-Path $script:baseDir ".watcher.lock"
            if (Test-Path $oldLock) {
                $lockPid = [int]([System.IO.File]::ReadAllText($oldLock, $script:utf8).Trim())
                if ($lockPid -eq $PID) {
                    Remove-Item $oldLock -Force -ErrorAction SilentlyContinue
                    Log "[HOUSEKEEP] Removed obsolete .watcher.lock (own PID)"
                } elseif (-not (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
                    Remove-Item $oldLock -Force -ErrorAction SilentlyContinue
                    Log "[HOUSEKEEP] Removed stale .watcher.lock (PID=$lockPid not alive)"
                }
            }
        } catch { }

        # Gap 6: Memory pressure warning (V22.1)
        try {
            $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($osInfo) {
                $freeMB = [math]::Round($osInfo.FreePhysicalMemory / 1024, 0)
                $totalMB = [math]::Round($osInfo.TotalVisibleMemorySize / 1024, 0)
                $pctFree = [math]::Round(($osInfo.FreePhysicalMemory / $osInfo.TotalVisibleMemorySize) * 100, 1)
                if ($pctFree -lt 10) {
                    Log "[MEMORY] WARNING — ${freeMB}MB free / ${totalMB}MB total (${pctFree}%) — system critically low"
                } elseif ($pctFree -lt 20) {
                    Log "[MEMORY] Low — ${freeMB}MB free / ${totalMB}MB total (${pctFree}%)"
                }
            }
        } catch { }
    }
}
