#Requires -Version 5.0
param([string]$WorkerDir = $(throw "WorkerDir required"))
$ErrorActionPreference = "Continue"
$utf8 = [System.Text.UTF8Encoding]::new($false)
$queueFile = Join-Path $WorkerDir "queue.txt"
$logFile = Join-Path $WorkerDir "worker.log"
$heartbeatFile = Join-Path $WorkerDir ".heartbeat"
$lockFile = Join-Path $WorkerDir ".lock"
$pipeName = "Cluster_Wkr_wsl"
$idleJson = '{"v":3,"state":"idle"}'

function TLog($m) {
    try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($logFile,"$t | [WSL] $m`r`n",$utf8) } catch {}
}
function WriteF($p,$c) {
    for ($i=0; $i -lt 3; $i++) { try { [System.IO.File]::WriteAllText($p,$c,$utf8); return } catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 20 } }
}
function ReadJ($p) {
    if (-not (Test-Path $p)) { return $null }
    for ($i=0; $i -lt 3; $i++) { try { $t=[System.IO.File]::ReadAllText($p,$utf8); if ([string]::IsNullOrWhiteSpace($t)) { return $null }; return ($t|ConvertFrom-Json) } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 20 } }
}

# ── V4: Smart execution ──
function ExecCmd($cid, $raw, $ctype, $timeout) {
    $exitCode = -1; $stdout = ""; $stderr = ""; $errorMsg = ""; $t0 = Get-Date
    $normType = if ($ctype -eq "c" -or $ctype -eq "cmd") { "cmd" }
                elseif ($ctype -eq "p" -or $ctype -eq "powershell" -or $ctype -eq $null) { "powershell" }
                elseif ($ctype -eq "i" -or $ctype -eq "__INLINE__") { "inline" }
                elseif ($ctype -eq "w" -or $ctype -eq "wsl") { "wsl" }
                else { $ctype }

    if ($normType -eq "inline" -or $normType -eq "powershell") {
        # V4: Inline execution in worker process (10ms vs 800ms)
        try { $sb=[ScriptBlock]::Create($raw); $r=&$sb; if ($r -ne $null) { $stdout=($r|Out-String).Trim() }; $exitCode=0; TLog "  [$cid] INLINE/PS done $(((Get-Date)-$t0).TotalMilliseconds.ToString('0'))ms" }
        catch { $errorMsg=$_.Exception.Message; $exitCode=-1; TLog "  [$cid] err: $errorMsg" }
    } elseif ($normType -eq "wsl") {
        $outF=Join-Path $WorkerDir "wsl_o_${cid}.txt"; $batF=Join-Path $WorkerDir "wsl_b_${cid}.bat"
        try { $escaped=$raw -replace "'","'\''"
            $batContent="@chcp 65001 >nul`r`nwsl.exe -e bash -c '$escaped' > `"%outF%`" 2>&1`r`ntype `"%outF%`"`r`n"
            [System.IO.File]::WriteAllText($batF,$batContent,[Text.Encoding]::ASCII)
            $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName="cmd.exe"; $psi.Arguments="/c `"$batF`""; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
            $p=[System.Diagnostics.Process]::Start($psi)
            if ($p -and $p.WaitForExit(($timeout+2)*1000)) { Start-Sleep -Milliseconds 300; $stdout=$p.StandardOutput.ReadToEnd(); $exitCode=$p.ExitCode; $p.Dispose() } else { if ($p) { $p.Kill(); $p.Dispose() }; $stdout="[TIMEOUT]"; $errorMsg="TIMEOUT" }
        } catch { $errorMsg=$_.Exception.Message; TLog "  EX: $errorMsg" }
        if (Test-Path $outF) { try { $b=[System.IO.File]::ReadAllBytes($outF); if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $stdout=[Text.Encoding]::Unicode.GetString($b); TLog "  UTF-16LE fix" } else { $stdout=$utf8.GetString($b) }; $stdout=$stdout.Trim() } catch {}; try { Remove-Item $outF -Force -ErrorAction SilentlyContinue } catch {} }
        $stdout=$stdout -replace "`0",""; try { Remove-Item $batF -Force -ErrorAction SilentlyContinue } catch {}
        TLog "  [$cid] WSL e=$exitCode o=$($stdout.Length)chars"
    } else {
        # cmd: sub-process
        try { $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
            if ($normType -eq "cmd") { $psi.FileName="cmd.exe"; $psi.Arguments="/c $raw" }
            else { $psi.FileName="powershell.exe"; $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw)); $psi.Arguments="-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
            $p=[System.Diagnostics.Process]::Start($psi)
            if ($p -and $p.WaitForExit(($timeout+2)*1000)) { Start-Sleep -Milliseconds 100; $stdout=$p.StandardOutput.ReadToEnd() -replace "`0",""; $stderr=$p.StandardError.ReadToEnd() -replace "`0",""; $exitCode=$p.ExitCode; $p.Dispose(); TLog "  [$cid] exit=$exitCode o=$($stdout.Length)chars" }
            else { if ($p) { $p.Kill(); $p.Dispose() }; $stdout="[TIMEOUT]"; $errorMsg="TIMEOUT" }
        } catch { $errorMsg=$_.Exception.Message; TLog "  [$cid] EX: $errorMsg" }
    }
    $elapsed=[int]((Get-Date)-$t0).TotalMilliseconds
    return @{state=if ($errorMsg){"error"}else{"done"}; id=$cid; e=$exitCode; o=$stdout; s=$stderr; err=$errorMsg; d=$elapsed; ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
}
function WriteResult($res) {
    $jsonStr = $res | ConvertTo-Json -Depth 1 -Compress
    WriteF (Join-Path $WorkerDir "r_$($res.id).json") $jsonStr
    try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result_$($res.id)"); $e.Set(); $e.Dispose() } catch {}
    try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result"); $e.Set(); $e.Dispose() } catch {}
    TLog "  [$($res.id)] written o=$(([string]$res.o).Length)chars in $($res.d)ms"
}

try { [System.IO.File]::WriteAllText($lockFile,[string]$PID,$utf8); TLog "PID=$PID lock" } catch { TLog "Lock fail: $_" }
$signalEvent=$null
try { $signalEvent=New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::AutoReset,"Local\Cluster_Wkr_wsl"); TLog "Event OK" } catch { TLog "Event N/A" }
TLog "=== V4 WSL Worker STARTED === pipe=$pipeName (inline+subprocess)"
WriteF $queueFile $idleJson; TLog "Ready"

# ── File monitor background runspace ──
$filePs=[PowerShell]::Create()
$null=$filePs.AddScript({
    param($d, $wn)
    $utf8=[System.Text.UTF8Encoding]::new($false); $qf=Join-Path $d "queue.txt"; $lf=Join-Path $d "worker.log"; $hb=Join-Path $d ".heartbeat"
    function TLogf($m) { try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($lf,"$t | [FILE] $m`r`n",$utf8) } catch {} }
    function ReadJf($p) { if (-not (Test-Path $p)) { return $null }; for ($i=0; $i -lt 3; $i++) { try { $t=[System.IO.File]::ReadAllText($p,$utf8); if ([string]::IsNullOrWhiteSpace($t)) { return $null }; return ($t|ConvertFrom-Json) } catch { if ($i -eq 2) { return $null }; Start-Sleep -Milliseconds 20 } } }
    function WriteFf($p,$c) { for ($i=0; $i -lt 3; $i++) { try { [System.IO.File]::WriteAllText($p,$c,$utf8); return } catch { if ($i -eq 2) { throw }; Start-Sleep -Milliseconds 20 } } }
    TLogf "File monitor started"; $lastId=""
    $fileEvent=$null; try { $fileEvent=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Wkr_wsl") } catch {}
    while ($true) {
        try { [System.IO.File]::WriteAllText($hb,(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"),$utf8) } catch {}
        if ($fileEvent) { $null=$fileEvent.WaitOne(500) } else { Start-Sleep -Milliseconds 200 }
        $q=ReadJf $qf
        if ($q -and $q.state -eq "pending" -and $q.cmd_id -ne "" -and $q.cmd_id -ne $lastId) {
            $lastId=$q.cmd_id; $cid=$q.cmd_id; $raw=$q.command; $ctype=$q.type; $timeout=30
            if ([string]::IsNullOrWhiteSpace($ctype)) { $ctype="powershell" }
            if ($q.timeout -gt 0) { $timeout=$q.timeout }; if ($q.t) { $ctype=$q.t }; if ($q.to) { $timeout=$q.to }
            TLogf "[$cid] type=$ctype cmd=$raw"; WriteFf $qf ('{"v":3,"state":"r","id":"'+$cid+'"}')
            $exitCode=-1; $stdout=""; $stderr=""; $errorMsg=""; $t0=Get-Date
            $normType = if ($ctype -eq "c" -or $ctype -eq "cmd") { "cmd" }
                        elseif ($ctype -eq "p" -or $ctype -eq "powershell") { "powershell" }
                        elseif ($ctype -eq "i" -or $ctype -eq "__INLINE__") { "inline" }
                        elseif ($ctype -eq "w" -or $ctype -eq "wsl") { "wsl" }
                        else { $ctype }
            try {
                if ($normType -eq "inline" -or $normType -eq "powershell") {
                    # V4 inline
                    $sb=[ScriptBlock]::Create($raw); $r=&$sb; if ($r -ne $null) { $stdout=($r|Out-String).Trim() }; $exitCode=0
                    TLogf "  ScriptBlock $(((Get-Date)-$t0).TotalMilliseconds.ToString('0'))ms"
                } elseif ($normType -eq "wsl") {
                    $outF=Join-Path $d "wsl_o_${cid}.txt"; $batF=Join-Path $d "wsl_b_${cid}.bat"
                    try { $escaped=$raw -replace "'","'\''"
                        $batContent="@chcp 65001 >nul`r`nwsl.exe -e bash -c '$escaped' > `"%outF%`" 2>&1`r`ntype `"%outF%`"`r`n"
                        [System.IO.File]::WriteAllText($batF,$batContent,[Text.Encoding]::ASCII)
                        $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName="cmd.exe"; $psi.Arguments="/c `"$batF`""; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
                        $p=[System.Diagnostics.Process]::Start($psi)
                        if ($p -and $p.WaitForExit(($timeout+2)*1000)) { Start-Sleep -Milliseconds 300; $stdout=$p.StandardOutput.ReadToEnd(); $exitCode=$p.ExitCode; $p.Dispose() } else { if ($p) { $p.Kill(); $p.Dispose() }; $stdout="[TIMEOUT]"; $errorMsg="TIMEOUT" }
                    } catch { $errorMsg=$_.Exception.Message }
                    if (Test-Path $outF) { try { $b=[System.IO.File]::ReadAllBytes($outF); if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { $stdout=[Text.Encoding]::Unicode.GetString($b); TLogf "  UTF-16LE fix" } else { $stdout=$utf8.GetString($b) }; $stdout=$stdout.Trim() } catch {}; try { Remove-Item $outF -Force -ErrorAction SilentlyContinue } catch {} }
                    $stdout=$stdout -replace "`0",""; try { Remove-Item $batF -Force -ErrorAction SilentlyContinue } catch {}
                } else {
                    $psi=New-Object System.Diagnostics.ProcessStartInfo; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.StandardOutputEncoding=$utf8; $psi.StandardErrorEncoding=$utf8
                    if ($normType -eq "cmd") { $psi.FileName="cmd.exe"; $psi.Arguments="/c $raw" }
                    else { $psi.FileName="powershell.exe"; $enc=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($raw)); $psi.Arguments="-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" }
                    $p=[System.Diagnostics.Process]::Start($psi)
                    if ($p -and $p.WaitForExit(($timeout+2)*1000)) { Start-Sleep -Milliseconds 100; $stdout=$p.StandardOutput.ReadToEnd() -replace "`0",""; $stderr=$p.StandardError.ReadToEnd() -replace "`0",""; $exitCode=$p.ExitCode; $p.Dispose() }
                    else { if ($p) { $p.Kill(); $p.Dispose() }; $stdout="[TIMEOUT]"; $errorMsg="TIMEOUT" }
                }
            } catch { $errorMsg=$_.Exception.Message; TLogf "  EX: $errorMsg" }
            $elapsed=[int]((Get-Date)-$t0).TotalMilliseconds
            $res=@{state="done"; id=$cid; e=$exitCode; o=$stdout; s=$stderr; err=$errorMsg; d=$elapsed; ts=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")}
            WriteFf (Join-Path $d "r_${cid}.json") ($res|ConvertTo-Json -Depth 1 -Compress)
            try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result_$cid"); $e.Set(); $e.Dispose() } catch {}
            try { $e=[System.Threading.EventWaitHandle]::OpenExisting("Local\Cluster_Result"); $e.Set(); $e.Dispose() } catch {}
            TLogf "  [$cid] done $($stdout.Length)chars in ${elapsed}ms"; WriteFf $qf '{"v":3,"state":"idle"}'; TLogf "  queue reset"
        }
        Start-Sleep -Milliseconds 100
    }
}).AddArgument($WorkerDir).AddArgument("wsl")
$fileAsync=$filePs.BeginInvoke()

# ── Main thread: Named Pipe Server ──
while ($true) {
    try { [System.IO.File]::WriteAllText($heartbeatFile,(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"),$utf8) } catch {}
    $pipe=$null
    try {
        $pipe=New-Object System.IO.Pipes.NamedPipeServerStream($pipeName,[System.IO.Pipes.PipeDirection]::InOut,1,[System.IO.Pipes.PipeTransmissionMode]::Message)
        $pipe.WaitForConnection()
        $reader=New-Object System.IO.StreamReader($pipe); $writer=New-Object System.IO.StreamWriter($pipe); $writer.AutoFlush=$true
        $cmdJson=$reader.ReadLine()
        if (-not [string]::IsNullOrWhiteSpace($cmdJson)) { $q=$cmdJson|ConvertFrom-Json; $cid=$q.id; $raw=$q.c; $ctype=$q.t; $timeout=30; if ([string]::IsNullOrWhiteSpace($ctype)) { $ctype="powershell" }; if ($q.to -gt 0) { $timeout=$q.to }; TLog "[PIPE] [$cid] type=$ctype to=${timeout}s"; $res=ExecCmd $cid $raw $ctype $timeout; $jsonStr=$res|ConvertTo-Json -Depth 1 -Compress; $writer.WriteLine($jsonStr); WriteResult $res }
        $pipe.Disconnect()
    } catch {} finally { if ($pipe) { try { $pipe.Close() } catch {} } }
    Start-Sleep -Milliseconds 5
}
