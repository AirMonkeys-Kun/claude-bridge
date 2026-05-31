# elevate_ti.ps1 — Elevate watcher to TrustedInstaller level
$dir = "C:\Users\wsx\Desktop\claude-bridge\watcher"
$log = Join-Path $dir "watcher.log"
$ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")

# Step 1: Make sure TrustedInstaller service is running
sc start TrustedInstaller 2>$null
Start-Sleep 2

# Step 2: Find TrustedInstaller PID
$tiProc = Get-Process -Name "TrustedInstaller" -ErrorAction SilentlyContinue
if (-not $tiProc) {
    "$ts | [TI] TrustedInstaller process not found" | Out-File $log -Append
    exit 1
}
$tiPid = $tiProc.Id
"$ts | [TI] Found TrustedInstaller PID=$tiPid" | Out-File $log -Append

# Step 3: C# code to duplicate TrustedInstaller token and launch watcher
$csCode = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class TI {
    [DllImport("kernel32")] public static extern IntPtr OpenProcess(uint a, bool b, uint c);
    [DllImport("advapi32")] public static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32")] public static extern bool DuplicateTokenEx(IntPtr e, uint a, IntPtr n, uint l, uint tp, out IntPtr d);
    [DllImport("advapi32", CharSet=CharSet.Unicode)] public static extern bool CreateProcessWithTokenW(IntPtr t, uint f, string a, string c, uint cf, IntPtr e, string d, ref SI si, out PI pi);
    [StructLayout(LayoutKind.Sequential)] public struct SI { public uint cb; string r; string d; string t; uint x; uint y; uint xs; uint ys; uint xc; uint yc; uint fa; uint f; ushort w; ushort c; IntPtr r2; IntPtr hi; IntPtr ho; IntPtr he; }
    [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr p; public IntPtr t; public uint pid; public uint tid; }

    public static void Run(int targetPid, string app, string args) {
        // Enable required privileges
        IntPtr hToken;
        OpenProcessToken(Process.GetCurrentProcess().Handle, 0x0020 | 0x0008, out hToken);

        // Open target process (TrustedInstaller)
        IntPtr hProc = OpenProcess(0x0400 | 0x0008, false, (uint)targetPid);
        if (hProc == IntPtr.Zero) { Console.Write("ERR:OpenProcess"); return; }

        // Open its token
        IntPtr tiToken;
        if (!OpenProcessToken(hProc, 0x0002 | 0x0008 | 0x0001, out tiToken)) {
            Console.Write("ERR:OpenProcessToken"); return;
        }

        // Duplicate token as primary
        IntPtr dupToken;
        if (!DuplicateTokenEx(tiToken, 0x1FFFFF, IntPtr.Zero, 2, 1, out dupToken)) {
            Console.Write("ERR:DuplicateTokenEx"); return;
        }

        // Create process with duplicated token
        SI si = new SI();
        si.cb = (uint)Marshal.SizeOf(typeof(SI));
        PI pi;

        if (!CreateProcessWithTokenW(dupToken, 0, app, args, 0x10, IntPtr.Zero, null, ref si, out pi)) {
            Console.Write("ERR:CreateProcess=" + Marshal.GetLastWin32Error());
            return;
        }

        Console.Write("OK_PID=" + pi.pid);
    }
}
"@

# Step 4: Compile C# code with Add-Type
try {
    $asm = Add-Type -TypeDefinition $csCode -Language CSharp -PassThru -ErrorAction Stop
    "$ts | [TI] C# compiled OK" | Out-File $log -Append
} catch {
    "$ts | [TI] C# compile error: $_" | Out-File $log -Append
    exit 1
}

# Step 5: Execute to launch a SYSTEM-level watcher from TrustedInstaller token
$watcherPath = "$dir\watcher.ps1"
try {
    $result = [TI]::Run($tiPid, "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File `"$watcherPath`"")
    "$ts | [TI] Result: $result" | Out-File $log -Append
} catch {
    "$ts | [TI] Execute error: $_" | Out-File $log -Append
}
