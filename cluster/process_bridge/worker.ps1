#Requires -Version 5.0
param([string]$WorkerDir = $(throw "WorkerDir required"))
$ErrorActionPreference = "Continue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$queueFile = Join-Path $WorkerDir "queue.txt"
$logFile = Join-Path $WorkerDir "worker.log"
$heartbeatFile = Join-Path $WorkerDir ".heartbeat"
$lockFile = Join-Path $WorkerDir ".lock"
$workerName = [System.IO.Path]::GetFileName($WorkerDir) -replace '_bridge', ''
$pipeName = "Cluster_Wkr_$workerName"
$idleJson = '{"v":3,"state":"idle"}'

function TLog($m) {
    try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($logFile,"$t | $m`r`n",$utf8) } catch {}
}
function WriteF($p,$c) {
    for ($i=0; $i -lt 3; $i++) { try { [System.IO.File]::WriteAllText($p,$c,$utf8); return } catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 20 } }
}
function ReadJ($p) {
    if (-not (Test-Path $p)) { return $null }
    for ($i=0; $i -lt 3; $i++) { try { $t=[System.IO.File]::ReadAllText($p,$utf8); if ([string]::IsNullOrWhiteSpace($t)) { return $null }; return ($t|ConvertFrom-Json) } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 20 } }
}

function ExecCmd($cid,$raw,$ctype,$timeout) {
    $exitCode=-1; $stdout=""; $stderr=""; $errorMsg=""; $t0=Get-Date
    if ($ctype -eq "__INLINE__" -or $ctype -eq "i") {
        try { $sb=[ScriptBlock]::Create($raw); $r=&$sb; if ($r -ne $null) { $stdout=($r|Out-String).Trim() }; $exitCode=0; TLog "  [$cid] INLINE done" } catch { $errorMsg=$_.Exception.Message; $exitCode=-1; TLog "  [$cid] INLINE err" }
    } else {
        try { $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
            if ($ctype -eq "cmd" -or $ctype -eq "c") { $psi.FileName="cmd.exe"; $psi.Arguments="/c $raw" }
            elseif ($ctype -eq "wsl" -or $ctype -eq "w") { $psi.FileName="cmd.exe"; $psi.Arguments="/c wsl.exe -e bash -c '$raw'" }
            else { $psi.FileName="powershell.exe"; $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw)); $psi.Arguments="-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
            $p=[System.Diagnostics.Process]::Start($psi)
            if ($p -and $p.WaitForExit(($timeout+2)*1000)) { Start-Sleep -Milliseconds 150; $stdout=$p.StandardOutput.ReadToEnd(); $stderr=$p.StandardError.ReadToEnd(); $stdout=$stdout -replace "`0",""; $stderr=$stderr -replace "`0",""; $exitCode=$p.ExitCode; $p.Dispose(); TLog "  [$cid] exit=$exitCode o=$($stdout.Length)chars" }
            else { if ($p) { $p.Kill(); $p.Dispose() }; $stdout="[TIMEOUT]"; $errorMsg="TIMEOUT" }
        } catch { $errorMsg=$_.Exception.Message; TLog "  [$cid] EX: $errorMsg" }
    }
    $elapsed=[int]((Get-Date)-$t0).TotalMilliseconds
    # Return both compact (v5 legacy) and full format for compatibility
    return @{state="done"; id=$cid; cmd_id=$cid; e=$exitCode; exit_code=$exitCode; o=$stdout; stdout=$stdout; s=$stderr; stderr=$stderr; err=$errorMsg; error=$errorMsg; d=$elapsed; duration_ms=$elapsed; ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
}
function WriteResult($res) {
    $jsonStr = $res | ConvertTo-Json -Depth 1 -Compress
    WriteF (Join-Path $WorkerDir "r_$($res.id).json") $jsonStr
    try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result"); $e.Set(); $e.Dispose() } catch {}
    TLog "  [$($res.id)] written o=$(([string]$res.o).Length)chars in $($res.d)ms"
}

try { [System.IO.File]::WriteAllText($lockFile,[string]$PID,$utf8); TLog "PID=$PID lock" } catch { TLog "Lock fail: $_" }
$signalEvent=$null
try { $signalEvent=New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::AutoReset,"Local\Cluster_Wkr_$workerName"); TLog "Event OK" } catch { TLog "Event N/A" }

TLog "=== V3 Worker STARTED === pipe=$pipeName"
WriteF $queueFile $idleJson
TLog "Ready"

# ── File monitor background runspace ──
$filePs=[PowerShell]::Create()
$null=$filePs.AddScript({
    param($d)
    $utf8=[System.Text.UTF8Encoding]::new($false); $qf=Join-Path $d "queue.txt"; $lf=Join-Path $d "worker.log"; $hb=Join-Path $d ".heartbeat"
    function TLogf($m) { try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($lf,"$t | [FILE] $m`r`n",$utf8) } catch {} }
    function ReadJf($p) { if (-not (Test-Path $p)) { return $null }; for ($i=0; $i -lt 3; $i++) { try { $t=[System.IO.File]::ReadAllText($p,$utf8); if ([string]::IsNullOrWhiteSpace($t)) { return $null }; return ($t|ConvertFrom-Json) } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 20 } } }
    function WriteFf($p,$c) { for ($i=0; $i -lt 3; $i++) { try { [System.IO.File]::WriteAllText($p,$c,$utf8); return } catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 20 } } }
    TLogf "File monitor started"; $lastId=""; $contentCache=@{}
    while ($true) {
        try { [System.IO.File]::WriteAllText($hb,(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"),$utf8) } catch {}
        $q=ReadJf $qf
        if ($q -and $q.state -eq "pending" -and $q.cmd_id -ne "" -and $q.cmd_id -ne $lastId) {
            # V13: Content-hash dedup
            $raw=$q.command
            if ($raw -and $raw.Length -gt 0) {
                $contentKey = $raw.Substring(0, [Math]::Min(300, $raw.Length))
                if ($contentCache.ContainsKey($contentKey)) {
                    $cachedAge = [int]((Get-Date) - $contentCache[$contentKey]).TotalMilliseconds
                    if ($cachedAge -lt 120000) {
                        TLogf "  [$($q.cmd_id)] CONTENT DEDUP HIT — skipping (${cachedAge}ms ago)"
                        WriteFf $qf '{"v":3,"state":"idle"}'
                        continue
                    }
                }
                $contentCache[$contentKey] = Get-Date
                if ($contentCache.Count -gt 50) {
                    $sorted = $contentCache.GetEnumerator() | Sort-Object { $_.Value } | Select-Object -First 10
                    foreach ($e in $sorted) { $contentCache.Remove($e.Key) }
                }
            }
            $lastId=$q.cmd_id; $cid=$q.cmd_id; $ctype=$q.type; $timeout=30
            if ([string]::IsNullOrWhiteSpace($ctype)) { $ctype="powershell" }
            if ($q.timeout -gt 0) { $timeout=$q.timeout }; if ($q.t) { $ctype=$q.t }; if ($q.to) { $timeout=$q.to }
            TLogf "[$cid] type=$ctype cmd=$raw"; WriteFf $qf ('{"v":3,"state":"r","id":"'+$cid+'"}')
            $exitCode=-1; $stdout=""; $stderr=""; $errorMsg=""; $t0=Get-Date
            if ($ctype -eq "__INLINE__" -or $ctype -eq "i") {
                try { $sb=[ScriptBlock]::Create($raw); $r=&$sb; if ($r -ne $null) { $stdout=($r|Out-String).Trim() }; $exitCode=0; TLogf "  INLINE done" } catch { $errorMsg=$_.Exception.Message; $exitCode=-1; TLogf "  INLINE err" }
            } else {
                try { $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
                    if ($ctype -eq "cmd" -or $ctype -eq "c") { $psi.FileName="cmd.exe"; $psi.Arguments="/c $raw" }
                    else { $psi.FileName="powershell.exe"; $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw)); $psi.Arguments="-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
                    $p=[System.Diagnostics.Process]::Start($psi)
                    if ($p -and $p.WaitForExit(($timeout+2)*1000)) { Start-Sleep -Milliseconds 150; $stdout=$p.StandardOutput.ReadToEnd(); $stderr=$p.StandardError.ReadToEnd(); $stdout=$stdout -replace "`0",""; $stderr=$stderr -replace "`0",""; $exitCode=$p.ExitCode; $p.Dispose() }
                    else { if ($p) { $p.Kill(); $p.Dispose() }; $stdout="[TIMEOUT]"; $errorMsg="TIMEOUT" }
                } catch { $errorMsg=$_.Exception.Message }
            }
            $elapsed=[int]((Get-Date)-$t0).TotalMilliseconds
            $res=@{state="done"; id=$cid; e=$exitCode; o=$stdout; s=$stderr; err=$errorMsg; d=$elapsed; ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            WriteFf (Join-Path $d "r_${cid}.json") ($res|ConvertTo-Json -Depth 1 -Compress)
            try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result"); $e.Set(); $e.Dispose() } catch {}
            TLogf "  [$cid] done $($stdout.Length)chars in ${elapsed}ms"; WriteFf $qf '{"v":3,"state":"idle"}'; TLogf "  queue reset"
        }
        Start-Sleep -Milliseconds 100
    }
}).AddArgument($WorkerDir)
$fileAsync=$filePs.BeginInvoke()

# ── Main thread: Named Pipe IPC ──
while ($true) {
    try { [System.IO.File]::WriteAllText($heartbeatFile,(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"),$utf8) } catch {}
    $pipe=$null
    try {
        $pipe=New-Object System.IO.Pipes.NamedPipeServerStream($pipeName,[System.IO.Pipes.PipeDirection]::InOut,1,[System.IO.Pipes.PipeTransmissionMode]::Message)
        $pipe.WaitForConnection()
        $reader=New-Object System.IO.StreamReader($pipe); $writer=New-Object System.IO.StreamWriter($pipe); $writer.AutoFlush=$true
        $cmdJson=$reader.ReadLine()
        if (-not [string]::IsNullOrWhiteSpace($cmdJson)) {
            $q=$cmdJson|ConvertFrom-Json; $cid=$q.id; $raw=$q.c; $ctype=$q.t; $timeout=30
            if ([string]::IsNullOrWhiteSpace($ctype)) { $ctype="powershell" }; if ($q.to -gt 0) { $timeout=$q.to }
            TLog "[PIPE] [$cid] type=$ctype to=${timeout}s"
            $res=ExecCmd $cid $raw $ctype $timeout
            $jsonStr = $res | ConvertTo-Json -Depth 1 -Compress
            $writer.WriteLine($jsonStr)
            WriteResult $res
        }
        $pipe.Disconnect()
    } catch { TLog "Pipe err: $($_.Exception.Message)" } finally { if ($pipe) { try { $pipe.Close() } catch {} } }
    Start-Sleep -Milliseconds 10
}
