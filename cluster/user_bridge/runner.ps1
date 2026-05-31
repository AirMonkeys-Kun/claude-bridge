#Requires -Version 5.0
<#
 Claude Bridge User Worker Runner V3
 ───────────────────────────────────
 SYSTEM-level bootstrap that spawns a user-context worker.
 Uses WTSQueryUserToken + CreateEnvironmentBlock + CreateProcessAsUser.
 V3: Uses compiled C# EXE (not inline) to avoid type-caching issues.
#>

$ErrorActionPreference = "Continue"
$bridgeBase = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $bridgeBase "bootstrap.log"
$startedFlag = Join-Path $bridgeBase ".user_bridge_started"
$workerScript = Join-Path $bridgeBase "worker.ps1"

$utf8 = [System.Text.UTF8Encoding]::new($false)

function TLog($m) {
    try { $t=(Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"); [System.IO.File]::AppendAllText($logFile,"$t | [BOOT] $m`r`n",$utf8) } catch {}
}

if (Test-Path $startedFlag) { TLog "Already started — exiting"; exit 0 }

# ── Compile standalone EXE for launching user process ──
$exePath = Join-Path $bridgeBase "launch_user.exe"
$csCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class LaunchUser {
    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll")] static extern bool WTSQueryUserToken(uint SessionId, out IntPtr phToken);
    [DllImport("advapi32.dll")] static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, SECURITY_IMPERSONATION_LEVEL ImpersonationLevel, TOKEN_TYPE TokenType, out IntPtr phNewToken);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUserW(IntPtr hToken, string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOW lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("userenv.dll", CharSet=CharSet.Unicode)] static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);
    [DllImport("userenv.dll")] static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);
    [DllImport("kernel32.dll")] static extern uint GetLastError();
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll")] static extern bool LookupPrivilegeValueW(string lpSystemName, string lpName, out LUID lpLuid);
    [DllImport("advapi32.dll")] static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();

    enum SECURITY_IMPERSONATION_LEVEL { SecurityAnonymous, SecurityIdentification, SecurityImpersonation, SecurityDelegation }
    enum TOKEN_TYPE { TokenPrimary = 1, TokenImpersonation }
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOW { public uint cb; string lpReserved; string lpDesktop; string lpTitle; uint dwX; uint dwY; uint dwXSize; uint dwYSize; uint dwXCountChars; uint dwYCountChars; uint dwFillAttribute; uint dwFlags; short wShowWindow; short cbReserved2; IntPtr lpReserved2; IntPtr hStdInput; IntPtr hStdOutput; IntPtr hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId; }

    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const uint TOKEN_QUERY = 0x0008;
    const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    const uint INFINITE = 0xFFFFFFFF;

    static int Main(string[] args) {
        if (args.Length < 2) { Console.Error.WriteLine("Usage: launch_user.exe <exe> <args>"); return 1; }
        string exePath = args[0];
        string cmdArgs = "";
        for (int i = 1; i < args.Length; i++) {
            if (i > 1) cmdArgs += " ";
            if (args[i].Contains(" ")) cmdArgs += "\"" + args[i] + "\"";
            else cmdArgs += args[i];
        }

        try {
            // Enable SeIncreaseQuotaPrivilege
            IntPtr hProcToken;
            if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hProcToken)) {
                LUID luid;
                if (LookupPrivilegeValueW(null, "SeIncreaseQuotaPrivilege", out luid)) {
                    TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                    tp.PrivilegeCount = 1; tp.Privileges.Luid = luid; tp.Privileges.Attributes = SE_PRIVILEGE_ENABLED;
                    AdjustTokenPrivileges(hProcToken, false, ref tp, (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(TOKEN_PRIVILEGES)), IntPtr.Zero, IntPtr.Zero);
                }
            }

            // Get user token
            uint sessionId = WTSGetActiveConsoleSessionId();
            if (sessionId == 0xFFFFFFFF) { Console.Error.WriteLine("No active session"); return 1; }

            IntPtr hUserToken;
            if (!WTSQueryUserToken(sessionId, out hUserToken)) { Console.Error.WriteLine("WTSQueryUserToken failed: " + GetLastError()); return 1; }

            // Duplicate as primary
            IntPtr hPrimaryToken;
            if (!DuplicateTokenEx(hUserToken, 0x1FFFFF, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenPrimary, out hPrimaryToken)) {
                Console.Error.WriteLine("DuplicateTokenEx failed: " + GetLastError()); return 1;
            }

            // Create environment block for user
            IntPtr envBlock;
            if (!CreateEnvironmentBlock(out envBlock, hPrimaryToken, false)) {
                Console.Error.WriteLine("CreateEnvironmentBlock failed: " + GetLastError()); return 1;
            }

            // Launch process
            STARTUPINFOW si = new STARTUPINFOW();
            si.cb = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(STARTUPINFOW));
            PROCESS_INFORMATION pi;
            StringBuilder cmdLine = new StringBuilder("\"" + exePath + "\" " + cmdArgs);

            if (!CreateProcessAsUserW(hPrimaryToken, null, cmdLine, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, envBlock, null, ref si, out pi)) {
                Console.Error.WriteLine("CreateProcessAsUser failed: " + GetLastError());
                DestroyEnvironmentBlock(envBlock);
                return 1;
            }

            Console.WriteLine("PID=" + pi.dwProcessId);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            DestroyEnvironmentBlock(envBlock);
            return 0;
        } catch (Exception ex) {
            Console.Error.WriteLine("EXCEPTION: " + ex.Message);
            return 1;
        }
    }
}
'@

# Compile
try {
    TLog "Compiling launch_user.exe..."
    Add-Type -TypeDefinition $csCode -Language CSharp -OutputType ConsoleApplication -OutputAssembly $exePath -ErrorAction Stop
    TLog "Compiled OK: $exePath"
} catch {
    TLog "Compile error: $_"
    exit 1
}

# Launch via compiled exe
$workerArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$workerScript`" -WorkerDir `"$bridgeBase`""
$psPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

TLog "Launching: $exePath $psPath $workerArgs"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exePath
$psi.Arguments = "`"$psPath`" $workerArgs"
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$p = [System.Diagnostics.Process]::Start($psi)
if (-not $p) { TLog "Failed to start launch_user.exe"; exit 1 }

$p.WaitForExit(15000)
$stdout = $p.StandardOutput.ReadToEnd().Trim()
$stderr = $p.StandardError.ReadToEnd().Trim()
$exitCode = $p.ExitCode
$p.Dispose()

TLog "launch_user exit=$exitCode stdout=$stdout stderr=$stderr"

if ($exitCode -eq 0 -and $stdout -match "^PID=(\d+)$") {
    $pid = $matches[1]
    TLog "Worker launched PID=$pid"
    Start-Sleep -Seconds 3
    if (Test-Path (Join-Path $bridgeBase "queue.txt")) {
        TLog "Worker initialized OK"
    } else {
        TLog "Queue not created yet (might take longer)"
    }
    [System.IO.File]::WriteAllText($startedFlag, "PID=$pid`r`nStarted: $(Get-Date)`r`nExe: $exePath", $utf8)
    TLog "Flag written"
} else {
    TLog "Failed to launch worker"
    exit 1
}

TLog "=== COMPLETE ==="