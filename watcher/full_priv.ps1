# full_priv.ps1 — Create a process with ALL privileges enabled + dump token info
$log = "C:\Users\wsx\Desktop\claude-bridge\watcher\watcher.log"
function Write-Log { param($m) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')) | [MAX] $m" | Out-File $log -Append }

Write-Log "Starting MAX privilege elevation..."

$csCode = @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class MaxPriv {
    [DllImport("advapi32")] static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32")] static extern bool GetTokenInformation(IntPtr t, uint c, IntPtr i, uint l, out uint r);
    [DllImport("advapi32")] static extern bool AdjustTokenPrivileges(IntPtr t, bool d, IntPtr n, uint l, IntPtr p, IntPtr r);
    [DllImport("advapi32")] static extern bool LookupPrivilegeName(string s, IntPtr id, System.Text.StringBuilder n, ref uint s2);
    [DllImport("advapi32", CharSet=CharSet.Unicode)] static extern bool CreateProcessWithTokenW(IntPtr t, uint f, string a, string c, uint cf, IntPtr e, string d, ref SI si, out PI pi);
    [DllImport("kernel32")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32")] static extern uint GetLastError();

    struct SI { public uint cb; IntPtr a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17; }
    struct PI { public IntPtr p,t; public uint pid,tid; }

    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint l; public int h; }
    [StructLayout(LayoutKind.Sequential)] struct LUID_AND_ATTRIBUTES { public LUID l; public uint a; }
    [StructLayout(LayoutKind.Sequential)] struct TOKEN_PRIVILEGES { public uint c; public LUID_AND_ATTRIBUTES p; }

    const uint TOKEN_QUERY = 0x0008;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    const uint TOKEN_DUPLICATE = 0x0002;
    const uint SE_PRIVILEGE_ENABLED = 0x00000002;

    public static string Run(string cmd) {
        try {
            // Get current process token with query + adjust
            IntPtr hToken;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES | TOKEN_DUPLICATE, out hToken))
                return "ERR:OpenProcessToken=" + GetLastError();

            // Query token privileges info
            uint sz = 0;
            GetTokenInformation(hToken, 1, IntPtr.Zero, 0, out sz); // TokenPrivileges=1
            if (sz == 0) return "ERR:GetTokenInfoSize";

            IntPtr buf = Marshal.AllocHGlobal((int)sz);
            if (!GetTokenInformation(hToken, 1, buf, sz, out sz))
                return "ERR:GetTokenInfo=" + GetLastError();

            // Parse privilege count
            uint count = (uint)Marshal.ReadInt32(buf);

            // Build the full TOKEN_PRIVILEGES with ALL privileges enabled
            int structSize = sizeof(uint) + count * Marshal.SizeOf(typeof(LUID_AND_ATTRIBUTES));
            IntPtr newBuf = Marshal.AllocHGlobal(structSize);
            Marshal.WriteInt32(newBuf, (int)count);

            int enabledCount = 0;
            for (int i = 0; i < count; i++) {
                int offset = sizeof(uint) + i * Marshal.SizeOf(typeof(LUID_AND_ATTRIBUTES));
                IntPtr p = IntPtr.Add(buf, offset);
                LUID_AND_ATTRIBUTES la = (LUID_AND_ATTRIBUTES)Marshal.PtrToStructure(p, typeof(LUID_AND_ATTRIBUTES));

                // Enable this privilege
                la.a |= SE_PRIVILEGE_ENABLED;
                Marshal.StructureToPtr(la, IntPtr.Add(newBuf, offset), false);
                enabledCount++;
            }

            // Apply the new privileges
            if (!AdjustTokenPrivileges(hToken, false, newBuf, (uint)structSize, IntPtr.Zero, IntPtr.Zero))
                return "ERR:Adjust=" + GetLastError();

            Marshal.FreeHGlobal(buf);
            Marshal.FreeHGlobal(newBuf);

            // Now create process with fully privileged token
            // Since we're SYSTEM, use CreateProcessWithTokenW with duplicated token
            IntPtr dupToken;
            if (!DuplicateTokenEx(hToken, 0x1FFFFF, IntPtr.Zero, 2, 1, out dupToken))
                return "ERR:DupToken=" + GetLastError();

            SI si = new SI(); si.cb = (uint)Marshal.SizeOf(typeof(SI));
            PI pi;

            if (!CreateProcessWithTokenW(dupToken, 0, "cmd.exe", cmd, 0x10, IntPtr.Zero, null, ref si, out pi))
                return "ERR:CreateProcess=" + GetLastError();

            return "OK_PID=" + pi.pid;
        } catch (Exception ex) {
            return "ERR:EX=" + ex.Message;
        }
    }
}
'@

try {
    Write-Log "Compiling C#..."
    $asm = Add-Type -TypeDefinition $csCode -Language CSharp -PassThru -ErrorAction Stop
    Write-Log "C# compiled OK"

    # Run: create cmd.exe with ALL privileges, whoami test
    $testCmd = "/c whoami > C:\\Windows\\Temp\\MAX_WHOAMI.txt & whoami /priv >> C:\\Windows\\Temp\\MAX_WHOAMI.txt & echo ALL_PRIVS_ENABLED >> C:\\Windows\\Temp\\MAX_WHOAMI.txt"
    $result = [MaxPriv]::Run($testCmd)
    Write-Log "Result: $result"

    Start-Sleep 2
    if (Test-Path "C:\Windows\Temp\MAX_WHOAMI.txt") {
        $content = Get-Content "C:\Windows\Temp\MAX_WHOAMI.txt" -Raw
        Write-Log "OUTPUT_FOLLOWS:"
        $content -split "`n" | ForEach-Object { Write-Log "  $_" }
    }
} catch {
    Write-Log "ERROR: $_"
}
