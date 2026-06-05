# send_vsock_doorbell.ps1 - Host-side Hyper-V socket doorbell sender
# Connects to vsock port 9999 on the Cowork VM to send instant doorbell notification
# Usage: .\send_vsock_doorbell.ps1 [-VmGuid <guid>] [-Timeout 5]
param(
    [string]$VmGuid = "",
    [int]$Timeout = 5
)

$ErrorActionPreference = "Stop"

# ---- VM GUID Discovery ----
function Find-CoworkVmGuid {
    # Method 0: HCS Registry (most reliable — VolatileStore\ComputeSystem)
    $hcsBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\HostComputeService\VolatileStore\ComputeSystem"
    if (Test-Path $hcsBase) {
        $vmGuids = Get-ChildItem $hcsBase -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName }
        if ($vmGuids -and $vmGuids.Count -gt 0) {
            Write-Host "Found VM in HCS registry: $($vmGuids[0])"
            return $vmGuids[0]
        }
    }

    # Method 1: Look for HCS state in ProgramData
    $vmDirs = @(
        "$env:ProgramData\Microsoft\Windows\Hyper-V\Virtual Machines",
        "$env:ProgramData\Microsoft\Windows\Hyper-V\data",
        "$env:ProgramData\Microsoft\Windows\Hyper-V\Virtual Hard Disks"
    )
    foreach ($dir in $vmDirs) {
        if (Test-Path $dir) {
            Get-ChildItem $dir -Recurse -Filter '*.vmcx' -ErrorAction SilentlyContinue | ForEach-Object {
                $xml = [xml](Get-Content $_.FullName -Raw)
                $guid = $xml.configuration.properties.name
                if ($guid) { return $guid }
            }
        }
    }

    # Method 2: Search for any GUID-like string in cowk-svc.exe's working directory
    $svcDir = Split-Path (Get-CimInstance Win32_Service -Filter "Name='CoworkVMService'").PathName -Parent
    if ($svcDir) {
        Get-ChildItem $svcDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            $content = Get-Content $_.FullName -Raw
            if ($content -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
                return $matches[0]
            }
        }
    }

    return ""
}

# ---- Hyper-V Socket API via C# ----
$HvSocketCode = @"
using System;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

public static class HvDoorbell
{
    const int AF_HYPERV = 34;
    const int HV_PROTOCOL_RAW = 1;
    const int SOCK_STREAM = 1;

    [DllImport("ws2_32.dll", SetLastError = true)]
    static extern IntPtr socket(int af, int type, int protocol);

    [DllImport("ws2_32.dll", SetLastError = true)]
    static extern int connect(IntPtr s, ref SOCKADDR_HV name, int namelen);

    [DllImport("ws2_32.dll", SetLastError = true)]
    static extern int send(IntPtr s, byte[] buf, int len, int flags);

    [DllImport("ws2_32.dll", SetLastError = true)]
    static extern int recv(IntPtr s, byte[] buf, int len, int flags);

    [DllImport("ws2_32.dll", SetLastError = true)]
    static extern int closesocket(IntPtr s);

    [DllImport("ws2_32.dll", SetLastError = true)]
    static extern int WSAGetLastError();

    [DllImport("ws2_32.dll")]
    static extern int WSAStartup(ushort wVersionRequested, out WSADATA lpWSAData);

    [DllImport("ws2_32.dll")]
    static extern int WSACleanup();

    [StructLayout(LayoutKind.Sequential)]
    struct WSADATA
    {
        public ushort wVersion;
        public ushort wHighVersion;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 257)]
        public byte[] szDescription;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 129)]
        public byte[] szSystemStatus;
        public ushort iMaxSockets;
        public ushort iMaxUdpDg;
        public IntPtr lpVendorInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SOCKADDR_HV
    {
        public ushort Family;
        public ushort Reserved;
        public Guid VmId;
        public Guid ServiceId;
    }

    // Convert vsock port number to Hyper-V service GUID
    // Standard mapping: {port, 0xfacb, 0x11e6, {0xbd, 0x58, 0x64, 0x00, 0x6a, 0x79, 0x86, 0xd3}}
    static Guid PortToServiceGuid(int port)
    {
        byte[] guidBytes = new byte[16];
        BitConverter.GetBytes(port).CopyTo(guidBytes, 0);
        guidBytes[4] = 0xcb; guidBytes[5] = 0xfa;
        guidBytes[6] = 0xe6; guidBytes[7] = 0x11;
        guidBytes[8] = 0xbd; guidBytes[9] = 0x58;
        guidBytes[10] = 0x64; guidBytes[11] = 0x00;
        guidBytes[12] = 0x6a; guidBytes[13] = 0x79;
        guidBytes[14] = 0x86; guidBytes[15] = 0xd3;
        return new Guid(guidBytes);
    }

    public static string SendDoorbell(string vmGuidStr, int port, int timeoutMs)
    {
        try
        {
            // Initialize WinSock
            WSADATA wsaData;
            int wsaResult = WSAStartup(0x0202, out wsaData);
            if (wsaResult != 0)
            {
                return "WSASTARTUP_ERR:" + wsaResult;
            }

            Guid vmGuid = Guid.Parse(vmGuidStr);
            Guid svcGuid = PortToServiceGuid(port);

            IntPtr sock = socket(AF_HYPERV, SOCK_STREAM, HV_PROTOCOL_RAW);
            if (sock == new IntPtr(-1))
            {
                int err = WSAGetLastError();
                WSACleanup();
                return "SOCKET_ERR:" + err;
            }

            SOCKADDR_HV addr = new SOCKADDR_HV();
            addr.Family = AF_HYPERV;
            addr.Reserved = 0;
            addr.VmId = vmGuid;
            addr.ServiceId = svcGuid;

            int ret = connect(sock, ref addr, Marshal.SizeOf(typeof(SOCKADDR_HV)));
            if (ret != 0)
            {
                int err = WSAGetLastError();
                closesocket(sock);
                WSACleanup();
                return "CONNECT_ERR:" + err;
            }

            // Connection = doorbell delivered! Read ACK
            byte[] buf = new byte[64];
            int received = recv(sock, buf, buf.Length, 0);
            string ack = System.Text.Encoding.ASCII.GetString(buf, 0, Math.Max(0, received));

            // Send a byte to confirm receipt
            send(sock, new byte[]{0x01}, 1, 0);

            closesocket(sock);
            WSACleanup();
            return "OK ACK=" + ack.Trim();
        }
        catch (Exception ex)
        {
            return "EXCEPTION: " + ex.Message;
        }
    }
}
"@

# ---- Main ----
Write-Host "=== VSOCK Doorbell Sender ==="
Write-Host "Time: $(Get-Date -Format 'HH:mm:ss.fff')"

# Find VM GUID if not provided
if (-not $VmGuid) {
    Write-Host "Searching for VM GUID..."
    $VmGuid = Find-CoworkVmGuid
    if (-not $VmGuid) {
        Write-Error "Could not find VM GUID. Pass -VmGuid parameter."
        exit 1
    }
}
Write-Host "VM GUID: $VmGuid"

# Compile C# code
Write-Host "Compiling Hyper-V socket helper..."
Add-Type -TypeDefinition $HvSocketCode -ErrorAction Stop

# Send doorbell
Write-Host "Sending doorbell to port 9999..."
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$result = [HvDoorbell]::SendDoorbell($VmGuid, 9999, $Timeout * 1000)
$timer.Stop()

Write-Host "Result: $result"
Write-Host "Latency: $($timer.ElapsedMilliseconds)ms"
Write-Host "=== Done ==="
exit 0
