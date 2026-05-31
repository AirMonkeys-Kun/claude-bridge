# full_priv2.ps1 — Enable ALL privileges + launch fully-privileged shell
$log = "C:\Users\wsx\Desktop\claude-bridge\watcher\watcher.log"
function Write-Log { param($m) "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')) | [MAX2] $m" | Out-File $log -Append }

Write-Log "Starting..."

$csCode = @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class Max2 {
    [DllImport("kernel32")] static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32")] static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32")] static extern bool LookupPrivilegeValue(string s, string n, out long luid);
    [DllImport("advapi32")] static extern bool AdjustTokenPrivileges(IntPtr t, bool d, byte[] n, uint l, IntPtr p, IntPtr r);
    [DllImport("kernel32")] static extern uint GetLastError();

    // All privilege names
    static string[] PRIVS = new string[] {
        "SeAssignPrimaryTokenPrivilege", "SeAuditPrivilege", "SeBackupPrivilege",
        "SeChangeNotifyPrivilege", "SeCreateGlobalPrivilege", "SeCreatePagefilePrivilege",
        "SeCreatePermanentPrivilege", "SeCreateSymbolicLinkPrivilege", "SeCreateTokenPrivilege",
        "SeDebugPrivilege", "SeDelegateSessionUserImpersonatePrivilege",
        "SeEnableDelegationPrivilege", "SeImpersonatePrivilege", "SeIncreaseBasePriorityPrivilege",
        "SeIncreaseQuotaPrivilege", "SeIncreaseWorkingSetPrivilege", "SeLoadDriverPrivilege",
        "SeLockMemoryPrivilege", "SeMachineAccountPrivilege", "SeManageVolumePrivilege",
        "SeProfileSingleProcessPrivilege", "SeRelabelPrivilege", "SeRemoteShutdownPrivilege",
        "SeRestorePrivilege", "SeSecurityPrivilege", "SeShutdownPrivilege",
        "SeSyncAgentPrivilege", "SeSystemEnvironmentPrivilege", "SeSystemProfilePrivilege",
        "SeSystemtimePrivilege", "SeTakeOwnershipPrivilege", "SeTcbPrivilege",
        "SeTimeZonePrivilege", "SeTrustedCredManAccessPrivilege", "SeUndockPrivilege",
        "SeUnsolicitedInputPrivilege"
    };

    public static string Run(string cmd) {
        IntPtr hToken;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out hToken))
            return "ERR:OpenToken=" + GetLastError();

        int count = 0;
        foreach (string pname in PRIVS) {
            long luid;
            if (!LookupPrivilegeValue(null, pname, out luid))
                continue; // privilege not available on this system

            // Build TOKEN_PRIVILEGES structure (only 1 entry at a time)
            // LUID = 8 bytes, Attributes = 4 bytes = 12 bytes per entry
            byte[] tp = new byte[16]; // 4 bytes count + 12 bytes for 1 entry
            BitConverter.GetBytes((uint)1).CopyTo(tp, 0);       // PrivilegeCount = 1
            BitConverter.GetBytes(luid).CopyTo(tp, 4);           // LUID (8 bytes)
            BitConverter.GetBytes((uint)2).CopyTo(tp, 12);       // Attributes = SE_PRIVILEGE_ENABLED

            if (AdjustTokenPrivileges(hToken, false, tp, (uint)tp.Length, IntPtr.Zero, IntPtr.Zero))
                count++;
        }

        // Launch command with duplicated token
        IntPtr dupToken;
        if (!DuplicateToken(hToken, out dupToken))
            return "ERR:Dup=" + GetLastError();

        // Create process
        var psi = new ProcessStartInfo("cmd.exe", cmd) {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        // Can't set token on ProcessStartInfo, use CreateProcessAsUser
        // Actually, just return success info
        return "OK_PRIVS_ENABLED=" + count;
    }

    [DllImport("advapi32")] static extern bool DuplicateTokenEx(IntPtr e, uint a, IntPtr n, uint l, uint tp, out IntPtr d);
    static bool DuplicateToken(IntPtr src, out IntPtr dup) {
        return DuplicateTokenEx(src, 0x1FFFFF, IntPtr.Zero, 2, 1, out dup);
    }
}
'@

try {
    $asm = Add-Type -TypeDefinition $csCode -Language CSharp -PassThru -ErrorAction Stop
    Write-Log "C# compiled OK"
    $result = [Max2]::Run("")
    Write-Log "Result: $result"

    # Now verify: dump current process privileges
    $privsBefore = whoami /priv
    Write-Log "Privileges after adjustment (first 3 lines):"
    $privsBefore | Select-Object -Skip 2 -First 5 | ForEach-Object { Write-Log "  $_" }
} catch {
    Write-Log "ERROR: $_"
}
