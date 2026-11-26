// Native helpers for FixMyDesktop. Kept C# 5 compatible so it compiles under Windows PowerShell 5.1.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace FixMyDesktop
{
    public sealed class MonitorInfo
    {
        public int Left, Top, Right, Bottom;          // full monitor bounds (virtual-screen pixels)
        public int WorkLeft, WorkTop, WorkRight, WorkBottom; // excludes the taskbar
        public bool Primary;
        public int Dpi = 96;
        public long Area { get { return (long)(Right - Left) * (Bottom - Top); } }
        // Size as it appears on screen: pixels divided by the scale factor, so a 1920x1200 laptop at 150% counts as 1280x800.
        public double EffectiveArea { get { double s = 96.0 / Dpi; return Area * s * s; } }
    }

    public static class Monitors
    {
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MONITORINFOEX
        {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
        }

        delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, IntPtr rect, IntPtr data);

        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFOEX mi);
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")] static extern uint GetDpiForSystem();
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hMon, int type, out uint dpiX, out uint dpiY);

        // The DPI that Explorer's reported icon spacing is based on.
        public static int SystemDpi()
        {
            try { return (int)GetDpiForSystem(); } catch (Exception) { return 96; }
        }

        // Without this, Windows reports scaled (virtualised) coordinates that don't match icon positions.
        public static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch (Exception) { }
            try { SetProcessDPIAware(); } catch (Exception) { }
        }

        public static MonitorInfo[] GetAll()
        {
            List<MonitorInfo> list = new List<MonitorInfo>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate(IntPtr h, IntPtr dc, IntPtr r, IntPtr d)
            {
                MONITORINFOEX mi = new MONITORINFOEX();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
                if (GetMonitorInfo(h, ref mi))
                {
                    MonitorInfo m = new MonitorInfo();
                    m.Left = mi.rcMonitor.Left; m.Top = mi.rcMonitor.Top;
                    m.Right = mi.rcMonitor.Right; m.Bottom = mi.rcMonitor.Bottom;
                    m.WorkLeft = mi.rcWork.Left; m.WorkTop = mi.rcWork.Top;
                    m.WorkRight = mi.rcWork.Right; m.WorkBottom = mi.rcWork.Bottom;
                    m.Primary = (mi.dwFlags & 1) != 0;
                    try
                    {
                        uint dx, dy;
                        if (GetDpiForMonitor(h, 0, out dx, out dy) == 0) m.Dpi = (int)dx;
                    }
                    catch (Exception) { }
                    list.Add(m);
                }
                return true;
            }, IntPtr.Zero);
            return list.ToArray();
        }
    }

    public static class NativeIcons
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);

        // Number of icons embedded in an exe/dll (0 = Windows shows its plain default icon).
        public static int Count(string path)
        {
            try { return (int)ExtractIconEx(path, -1, null, null, 0); } catch (Exception) { return -1; }
        }
    }

    // Raises a counter whenever displays change (dock/undock, monitor switch, unlock) so a script can poll it.
    public static class DisplayWatcher
    {
        public static int Counter;
        public static int LastTick;
        static bool started;

        public static void Start()
        {
            if (started) return;
            started = true;
            SystemEvents.DisplaySettingsChanged += delegate { Bump(); };
            SystemEvents.SessionSwitch += delegate(object s, SessionSwitchEventArgs e)
            {
                if (e.Reason == SessionSwitchReason.SessionUnlock || e.Reason == SessionSwitchReason.RemoteConnect) Bump();
            };
        }

        static void Bump()
        {
            LastTick = Environment.TickCount;
            System.Threading.Interlocked.Increment(ref Counter);
        }
    }

    // Talks to the desktop's SysListView32 (owned by explorer.exe) to read and move icons.
    public sealed class DesktopListView : IDisposable
    {
        const uint LVM_GETITEMCOUNT = 0x1004;
        const uint LVM_SETITEMPOSITION = 0x100F;
        const uint LVM_GETITEMPOSITION = 0x1010;
        const uint LVM_GETITEMSPACING = 0x1033;
        const uint LVM_GETEXTENDEDLISTVIEWSTYLE = 0x1037;
        const uint LVM_GETITEMTEXTW = 0x1073;
        const int GWL_STYLE = -16;
        const int LVS_AUTOARRANGE = 0x0100;
        const int LVS_EX_SNAPTOGRID = 0x00080000;
        const uint PROCESS_ACCESS = 0x0008 | 0x0010 | 0x0020 | 0x0400; // VM_OPERATION | VM_READ | VM_WRITE | QUERY_INFORMATION
        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint MEM_RELEASE = 0x8000;
        const uint PAGE_READWRITE = 0x04;
        const int TextOffset = 256;

        delegate bool EnumProc(IntPtr h, IntPtr l);

        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int index, int value);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, UIntPtr size, uint type, uint protect);
        [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, UIntPtr size, uint type);
        [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, int size, out IntPtr read);
        [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr addr, byte[] buf, int size, out IntPtr written);

        readonly IntPtr hwnd;
        readonly IntPtr process;
        readonly IntPtr remote;

        public DesktopListView()
        {
            if (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess)
                throw new InvalidOperationException("Run this from 64-bit PowerShell (explorer.exe is 64-bit).");

            hwnd = FindListView();
            if (hwnd == IntPtr.Zero)
                throw new InvalidOperationException("Could not find the desktop icon list (is explorer.exe running?).");

            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            process = OpenProcess(PROCESS_ACCESS, false, pid);
            if (process == IntPtr.Zero)
                throw new InvalidOperationException("Could not open explorer.exe (error " + Marshal.GetLastWin32Error() + ").");

            remote = VirtualAllocEx(process, IntPtr.Zero, new UIntPtr(4096), MEM_COMMIT_RESERVE, PAGE_READWRITE);
            if (remote == IntPtr.Zero)
                throw new InvalidOperationException("Could not allocate memory in explorer.exe.");
        }

        static IntPtr FindListView()
        {
            IntPtr defView = FindWindowEx(FindWindow("Progman", null), IntPtr.Zero, "SHELLDLL_DefView", null);
            if (defView == IntPtr.Zero)
            {
                // With some wallpaper setups the icons live under a WorkerW window instead of Progman.
                EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    StringBuilder sb = new StringBuilder(64);
                    GetClassName(h, sb, sb.Capacity);
                    if (sb.ToString() == "WorkerW")
                    {
                        IntPtr v = FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null);
                        if (v != IntPtr.Zero) { defView = v; return false; }
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return defView == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
        }

        public int Count { get { return SendMessage(hwnd, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero).ToInt32(); } }

        // Screen rectangle of the list view; icon coordinates are relative to its top-left corner.
        public int[] Origin
        {
            get { RECT r; GetWindowRect(hwnd, out r); return new int[] { r.Left, r.Top, r.Right, r.Bottom }; }
        }

        // Size of one icon cell (icon + label + padding) in pixels.
        public int[] Spacing
        {
            get
            {
                int v = SendMessage(hwnd, LVM_GETITEMSPACING, IntPtr.Zero, IntPtr.Zero).ToInt32();
                return new int[] { v & 0xFFFF, (v >> 16) & 0xFFFF };
            }
        }

        public bool AutoArrange
        {
            get { return (GetWindowLong(hwnd, GWL_STYLE) & LVS_AUTOARRANGE) != 0; }
            set
            {
                int style = GetWindowLong(hwnd, GWL_STYLE);
                style = value ? (style | LVS_AUTOARRANGE) : (style & ~LVS_AUTOARRANGE);
                SetWindowLong(hwnd, GWL_STYLE, style);
            }
        }

        public bool SnapToGrid
        {
            get { return (SendMessage(hwnd, LVM_GETEXTENDEDLISTVIEWSTYLE, IntPtr.Zero, IntPtr.Zero).ToInt32() & LVS_EX_SNAPTOGRID) != 0; }
        }

        public string GetName(int index)
        {
            bool x64 = IntPtr.Size == 8;
            int textPtrOffset = x64 ? 24 : 20;
            byte[] item = new byte[x64 ? 40 : 28];
            byte[] ptr = BitConverter.GetBytes(remote.ToInt64() + TextOffset);
            Array.Copy(ptr, 0, item, textPtrOffset, IntPtr.Size);
            Array.Copy(BitConverter.GetBytes(260), 0, item, textPtrOffset + IntPtr.Size, 4);

            IntPtr n;
            WriteProcessMemory(process, remote, item, item.Length, out n);
            int len = SendMessage(hwnd, LVM_GETITEMTEXTW, new IntPtr(index), remote).ToInt32();
            if (len <= 0) return "";

            byte[] text = new byte[len * 2];
            ReadProcessMemory(process, new IntPtr(remote.ToInt64() + TextOffset), text, text.Length, out n);
            return Encoding.Unicode.GetString(text);
        }

        public int[] GetPosition(int index)
        {
            IntPtr n;
            WriteProcessMemory(process, remote, new byte[8], 8, out n);
            SendMessage(hwnd, LVM_GETITEMPOSITION, new IntPtr(index), remote);
            byte[] buf = new byte[8];
            ReadProcessMemory(process, remote, buf, 8, out n);
            return new int[] { BitConverter.ToInt32(buf, 0), BitConverter.ToInt32(buf, 4) };
        }

        public void SetPosition(int index, int x, int y)
        {
            long lp = (long)(((uint)(y & 0xFFFF) << 16) | (uint)(x & 0xFFFF));
            SendMessage(hwnd, LVM_SETITEMPOSITION, new IntPtr(index), new IntPtr(lp));
        }

        public void Dispose()
        {
            if (remote != IntPtr.Zero) VirtualFreeEx(process, remote, UIntPtr.Zero, MEM_RELEASE);
            if (process != IntPtr.Zero) CloseHandle(process);
        }
    }
}
