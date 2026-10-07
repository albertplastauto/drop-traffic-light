# ============================================================================
#  Drop Traffic Light - desktop widget host (Windows, WebView2).
#  Author: Albert Kadantsev
#
#  Owns the window itself, so the widget can be genuinely frameless and
#  transparent: no title bar, no border, no taskbar button, and none of the
#  browser chrome that a hosted Chrome window cannot hide.
#
#    * the window is a WPF window with AllowsTransparency, sized exactly to the
#      case (54 : 46) and positioned where you ask;
#    * the page inside is WebView2 with a transparent default background, so
#      only the case is painted - the desktop shows through everywhere else and
#      clicks outside the case land on whatever is behind it;
#    * clicking the case opens the Harness UI in the everyday browser.
#
#  The managed WebView2 assemblies are fetched once from nuget.org into
#  %LOCALAPPDATA%\DropTrafficLight\lib; the WebView2 Runtime itself ships with
#  Windows 10/11.
#
#  Usage:  start-widget.bat                    (150 px case, top-right corner)
#          widget-host.ps1 -Width 220 -X 60 -Y 60 -Topmost
#          widget-host.ps1 -Stop                (remove from the desktop)
# ============================================================================
param(
  [int]$Width = 150,          # case width in DIP
  [int]$X = -1,               # -1 = snap to the right edge of the screen
  [int]$Y = 32,
  [switch]$Topmost,
  [switch]$Stop,
  [switch]$NoDownload,        # never touch the network; fail if the lib is missing
  [switch]$Debug              # log web messages from the page to host.log
)

$ErrorActionPreference = 'Stop'

$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Page  = Join-Path $Root 'index.html'
if (-not (Test-Path $Page)) { throw "index.html not found next to the host: $Page" }
$Url   = (New-Object System.Uri($Page)).AbsoluteUri + '#bg=none'
$Cache = Join-Path $env:LOCALAPPDATA 'DropTrafficLight'
$Lib   = Join-Path $Cache 'lib'
$Data  = Join-Path $Cache 'webview2'
$Ver   = '1.0.4258.31'      # matches the WebView2 Runtime shipped with Edge 154
$Ratio = 46 / 54
$Inner = 2                  # inset of the invisible click surface, in DIP

# ============================== REMOVE ==============================
# The host runs the widget in its own process, so removal means stopping that
# exact process. It is tracked by pid file - never by matching command lines,
# which would happily kill a shell that merely mentions this script.
$PidFile = Join-Path $Cache 'host.pid'

if ($Stop) {
  if (-not (Test-Path $PidFile)) { 'Widget is not running.'; return }
  $hostPid = 0
  [void][int]::TryParse((Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$hostPid)
  $name = Split-Path $MyInvocation.MyCommand.Path -Leaf
  $proc = if ($hostPid) { Get-CimInstance Win32_Process -Filter "ProcessId=$hostPid" -ErrorAction SilentlyContinue } else { $null }
  if ($proc -and $proc.CommandLine -like "*$name*") {
    Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue
    "Widget removed from the desktop (process $hostPid stopped)."
  } else {
    'Widget is not running.'
  }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  return
}

# ============================== BOOTSTRAP ==============================
function Get-WebView2Lib {
  $needed = @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll')
  $missing = @($needed | Where-Object { -not (Test-Path (Join-Path $Lib $_)) })
  if ($missing.Count -eq 0) { return }
  if ($NoDownload) { throw "Missing WebView2 assemblies in $Lib : $($missing -join ', ')" }

  Write-Host "Fetching WebView2 assemblies ($Ver) into $Lib ..."
  New-Item -ItemType Directory -Force -Path $Lib | Out-Null
  $zip = Join-Path $env:TEMP "webview2-$Ver.zip"
  $dir = Join-Path $env:TEMP "webview2-$Ver"
  if (-not (Test-Path $zip)) {
    Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$Ver" `
      -OutFile $zip -TimeoutSec 180 -UseBasicParsing
  }
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  foreach ($f in @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll')) {
    Copy-Item (Join-Path $dir "lib\net462\$f") $Lib -Force
  }
  Copy-Item (Join-Path $dir 'runtimes\win-x64\native\WebView2Loader.dll') $Lib -Force
}

Get-WebView2Lib

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -Path (Join-Path $Lib 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $Lib 'Microsoft.Web.WebView2.Wpf.dll')

# The widget draws itself with the WebView2 Runtime, which is a Windows component
# (shipped with Windows 11 and with Edge) - not a browser window and not tied to
# which browser you use. If it is missing, say so plainly and point at the
# fallback host instead of failing with a stack trace.
$runtimeVersion = $null
try { $runtimeVersion = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString() } catch { }
if (-not $runtimeVersion) {
  throw @'
WebView2 Runtime is not installed on this machine, so the widget has nothing to
draw itself with. Either install it (a small Microsoft component, it is what
Edge and many Windows apps already use):
    https://developer.microsoft.com/microsoft-edge/webview2/
or run the fallback host, which hosts the page in Edge or Chrome instead:
    widget-host-browser.ps1
'@
}

if (-not ('Widget.Win32' -as [type])) {
  Add-Type -Namespace Widget -Name Win32 -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
'@
}

# Where a click should lead. Read from the widget itself, so the address lives in
# exactly one place.
$HarnessUrl = 'http://127.0.0.1:19387'
try {
  $m = [regex]::Match((Get-Content $Page -Raw -Encoding UTF8), "HARNESS_URL\s*=\s*'([^']+)'")
  if ($m.Success) { $HarnessUrl = $m.Groups[1].Value }
} catch { }

# ============================== INSTALL ==============================
# One widget at a time.
if (Test-Path $PidFile) {
  $alive = 0
  [void][int]::TryParse((Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$alive)
  if ($alive -and (Get-Process -Id $alive -ErrorAction SilentlyContinue)) {
    'Widget is already on the desktop.'
    return
  }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

$caseW = [Math]::Max(60, $Width)
$caseH = [int][Math]::Round($caseW * $Ratio)

$screenW = [System.Windows.SystemParameters]::PrimaryScreenWidth
$screenH = [System.Windows.SystemParameters]::PrimaryScreenHeight

# Where the user last dragged it, unless a position was given on the command line.
$PosFile = Join-Path $Cache 'position.json'
if (-not $PSBoundParameters.ContainsKey('X') -and -not $PSBoundParameters.ContainsKey('Y') -and (Test-Path $PosFile)) {
  try {
    $pos = Get-Content $PosFile -Raw | ConvertFrom-Json
    $X = [int]$pos.left
    $Y = [int]$pos.top
    # a screen may be gone since then - keep the widget inside the current one
    if ($X -lt 0 -or $X -gt $screenW - $caseW - 8) { $X = -1 }
    if ($Y -lt 0 -or $Y -gt $screenH - $caseH - 8) { $Y = -1 }
  } catch { $X = -1; $Y = -1 }
}
if ($X -lt 0) { $X = [int]($screenW - $caseW - 32) }
if ($Y -lt 0) { $Y = 32 }

$win = New-Object System.Windows.Window
$win.WindowStyle      = [System.Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background       = [System.Windows.Media.Brushes]::Transparent
$win.ShowInTaskbar    = $false
$win.ResizeMode       = [System.Windows.ResizeMode]::NoResize
$win.Topmost          = [bool]$Topmost
$win.Width            = $caseW
$win.Height           = $caseH
$win.Left             = $X
$win.Top              = $Y
$win.Title            = 'Drop Traffic Light'

$web = New-Object Microsoft.Web.WebView2.Wpf.WebView2
$web.DefaultBackgroundColor = [System.Drawing.Color]::Transparent
$web.CreationProperties = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
$web.CreationProperties.UserDataFolder = $Data

# A per-pixel transparent window only accepts clicks where its own layered
# surface has opaque pixels - and everything visible here is painted by WebView2,
# a child window that does not contribute to that surface. Without an opaque
# shape underneath, every click would fall straight through to the desktop.
# The shape is inset and sits behind the browser, so it is never visible.
$hit = New-Object System.Windows.Controls.Border
$hit.CornerRadius = New-Object System.Windows.CornerRadius ([Math]::Max(0, $caseW * 0.24 - $Inner))
$hit.Margin       = New-Object System.Windows.Thickness $Inner, $Inner, $Inner, $Inner
$hit.Background   = [System.Windows.Media.Brushes]::Black
$hit.Child        = $web
$win.Content      = $hit

$web.add_CoreWebView2InitializationCompleted({
  param($sender, $ev)
  try {
    # Belt and braces: the page asks for a transparent background itself, but the
    # controller has to agree, otherwise WebView2 paints its own base colour.
    $sender.CoreWebView2Controller.DefaultBackgroundColor = [System.Drawing.Color]::Transparent

    $s = $sender.CoreWebView2.Settings
    $s.AreDefaultContextMenusEnabled = $false
    $s.AreDevToolsEnabled            = $false
    $s.IsStatusBarEnabled            = $false
    $s.IsZoomControlEnabled          = $false

    # If anything in the page still asks for a new window, hand the address to
    # the everyday browser instead of opening a second window inside the widget.
    $sender.CoreWebView2.add_NewWindowRequested({
      param($s2, $e2)
      $e2.Handled = $true
      try { Start-Process $e2.Uri } catch { }
    })
  } catch { }
})

$web.Source = [Uri]$Url
[void]$win.Show()

# --- right-click menu -------------------------------------------------------
# A desktop icon has its own menu, so the widget does too: open, keep on top,
# and remove from the desktop. The last one is the only way to close it, which
# matches the widget having no close button.
$menu = New-Object System.Windows.Controls.ContextMenu
$menu.FontSize = 13

$miOpen = New-Object System.Windows.Controls.MenuItem
$miOpen.Header = 'Open Harness'
$miOpen.Add_Click({ Open-Harness })
[void]$menu.Items.Add($miOpen)

$miTop = New-Object System.Windows.Controls.MenuItem
$miTop.Header = 'Always on top'
$miTop.IsCheckable = $true
$miTop.IsChecked = [bool]$Topmost
$miTop.Add_Click({ $win.Topmost = [bool]$miTop.IsChecked })
[void]$menu.Items.Add($miTop)

[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

$miQuit = New-Object System.Windows.Controls.MenuItem
$miQuit.Header = 'Remove from desktop'
$miQuit.Add_Click({
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  $win.Close()
})
[void]$menu.Items.Add($miQuit)

# --- behave like a desktop icon ---------------------------------------------
# The case is reported to Windows as a window caption. That is the whole trick:
# caption mouse messages go to the top-level window, so the browser's child
# windows can never swallow them, and Windows itself runs the move loop for
# dragging. A press that never moves is a click (opens Harness); a right-click
# opens the widget's own menu; everything outside the case is reported
# transparent, so those clicks fall through to the desktop as they should.
$hwnd   = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
$source = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
$radius = [Math]::Max(4.0, $caseW * 0.24)

function Write-Log {
  param([string]$text)
  if (-not $Debug) { return }
  try { Add-Content -Path (Join-Path $Cache 'host.log') -Value ("{0:HH:mm:ss} $text" -f (Get-Date)) } catch { }
}

# The answers to WM_NCHITTEST come from C#: PowerShell cannot hand a `ref bool`
# back through a delegate, so WPF would overwrite the answer. This one only deals
# with click-through outside the case; the mouse itself is handled by the
# low-level hook below.
if (-not ('WidgetMouseHook' -as [type])) {
  Add-Type -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase, System.Xaml -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

// The widget is a window whose picture is painted by WebView2 - a tree of child
// windows that would otherwise take every mouse message first. So the widget
// listens one level lower: a low-level mouse hook sees each press before any
// window does, which makes dragging, clicking and the context menu the widget's
// own business and keeps the browser's menu out of the picture entirely.
public class WidgetMouseHook
{
    public double W, H, R;
    public IntPtr Target;
    public object WpfWindow;          // the window is moved through WPF, so its own idea of Left/Top stays true
    public bool Dragging;             // the host follows this from a timer, not from the hook
    public bool Paused;               // true while the widget's menu owns the mouse
    public int CursorX, CursorY;
    public int RectLeft, RectTop;     // where the window really is right now
    public double ScaleX = 1.0, ScaleY = 1.0;
    public int MovesSeen;
    public Action OnClick, OnMenu, OnMoved;
    public Action OnPress;            // diagnostics: a left press was seen on the case

    private IntPtr _hook = IntPtr.Zero;
    private HookProc _proc;
    private int _grabX, _grabY, _startX, _startY, _moved;

    [DllImport("user32.dll")] private static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hk, int code, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MSLLHOOKSTRUCT { public POINT pt; public uint data; public uint flags; public uint time; public IntPtr extra; }

    public bool Install()
    {
        _proc = new HookProc(Callback);
        _hook = SetWindowsHookEx(14, _proc, IntPtr.Zero, 0);   // WH_MOUSE_LL
        return _hook != IntPtr.Zero;
    }

    public void Remove()
    {
        if (_hook != IntPtr.Zero) UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    private bool InCase(int x, int y)
    {
        RECT r;
        GetWindowRect(Target, out r);
        double px = x - r.Left;
        double py = y - r.Top;
        if (px < 0 || py < 0 || px > W || py > H) return false;
        if (px >= R && px <= W - R) return true;
        if (py >= R && py <= H - R) return true;
        double cx = px < R ? R : W - R;
        double cy = py < R ? R : H - R;
        return ((px - cx) * (px - cx) + (py - cy) * (py - cy)) <= R * R;
    }

    // Is the widget really the window under this point? Without this check a
    // press would reach the widget even when another application's window lies
    // on top of it: the widget would steal input from the window in front,
    // which is not how windows are supposed to behave.
    private bool Ours(int x, int y)
    {
        if (!IsWindowVisible(Target)) return false;
        POINT p;
        p.X = x;
        p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return false;
        return GetAncestor(h, 2) == Target;              // 2 = GA_ROOT
    }

    // Only three things are taken from the rest of the system: the left press on
    // the case (which becomes a drag), the right button (which becomes the
    // widget's own menu), and nothing else - moves and releases are ours only
    // while the drag lasts.
    private IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return CallNextHookEx(_hook, code, wParam, lParam);

        // While the widget's own menu is open the mouse belongs to the menu:
        // clicking an item, or anywhere else to dismiss it, must reach it.
        if (Paused) return CallNextHookEx(_hook, code, wParam, lParam);

        int msg = wParam.ToInt32();
        MSLLHOOKSTRUCT m = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
        bool inside = InCase(m.pt.X, m.pt.Y);

        if (msg == 0x0201)                                   // WM_LBUTTONDOWN
        {
            if (inside && Ours(m.pt.X, m.pt.Y))
            {
                RECT r;
                GetWindowRect(Target, out r);
                _grabX = m.pt.X - r.Left;                    // where inside the case the press landed
                _grabY = m.pt.Y - r.Top;
                _startX = m.pt.X;
                _startY = m.pt.Y;
                _moved = 0;
                MovesSeen = 0;
                CursorX = m.pt.X;
                CursorY = m.pt.Y;
                RectLeft = r.Left;
                RectTop = r.Top;
                Dragging = true;
                if (OnPress != null) OnPress();
                return (IntPtr)1;                            // the page never sees it
            }
            return CallNextHookEx(_hook, code, wParam, lParam);
        }

        if (msg == 0x0200 && Dragging)                       // WM_MOUSEMOVE while dragging
        {
            // Read where the pointer is, then let the event go on its way. A
            // low-level hook that swallows mouse moves freezes the pointer
            // itself, and the widget would chase a cursor that never moves.
            CursorX = m.pt.X;
            CursorY = m.pt.Y;
            MovesSeen++;
            _moved = Math.Abs(m.pt.X - _startX) + Math.Abs(m.pt.Y - _startY);
            return CallNextHookEx(_hook, code, wParam, lParam);
        }

        if (msg == 0x0202 && Dragging)                       // WM_LBUTTONUP
        {
            Dragging = false;
            if (_moved > 3) { if (OnMoved != null) OnMoved(); }
            else { if (OnClick != null) OnClick(); }
            return CallNextHookEx(_hook, code, wParam, lParam);
        }

        // The menu belongs to the *release*, the way Windows itself does it: the
        // right button goes down and comes up, and only then does the menu appear,
        // so nothing dismisses it the moment the finger lifts.
        if (inside && msg == 0x0204)                         // WM_RBUTTONDOWN
        {
            return (IntPtr)1;                                // never the browser's menu
        }
        if (inside && msg == 0x0205)                         // WM_RBUTTONUP
        {
            if (Ours(m.pt.X, m.pt.Y) && OnMenu != null) OnMenu();
            return (IntPtr)1;                                // the menu opens now, and stays
        }

        return CallNextHookEx(_hook, code, wParam, lParam);
    }

    // Put the window where the pointer says, in one step. The target is absolute,
    // so a dropped mouse event can only delay the widget - it can never make it
    // drift or fight with itself. Called by the host from its own timer, at a
    // steady pace, never from inside the mouse hook.
    //
    // SetWindowPos rather than Window.Left/Top: a WPF property change runs a
    // layout pass on every single mouse move, which is what made the widget
    // shudder while being dragged. This only moves the window.
    public void Place(int cursorX, int cursorY)
    {
        try
        {
            System.Windows.Window w = (System.Windows.Window)WpfWindow;
            System.Windows.PresentationSource src = System.Windows.PresentationSource.FromVisual(w);
            if (src != null && src.CompositionTarget != null)
            {
                ScaleX = src.CompositionTarget.TransformToDevice.M11;
                ScaleY = src.CompositionTarget.TransformToDevice.M22;
            }
            if (ScaleX <= 0) ScaleX = 1.0;
            if (ScaleY <= 0) ScaleY = 1.0;
            int x = cursorX - _grabX;
            int y = cursorY - _grabY;
            SetWindowPos(Target, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010);
            RectLeft = x;
            RectTop = y;
        }
        catch { }
    }

    // WPF keeps its own idea of Left/Top; after a drag the host writes the real
    // numbers back so the two agree again.
    public void SyncWpfPosition()
    {
        try
        {
            System.Windows.Window w = (System.Windows.Window)WpfWindow;
            w.Left = RectLeft / ScaleX;
            w.Top = RectTop / ScaleY;
        }
        catch { }
    }
}

// Clicking outside the case has to reach the desktop, so the window answers the
// hit test with HTTRANSPARENT there and HTCLIENT over the case itself. The same
// hook turns a press into a Windows move loop and tells a click from a drag.
public class WidgetHitHook
{
    public double W, H, R;

    [DllImport("user32.dll")] private static extern bool ScreenToClient(IntPtr hWnd, ref POINT p);
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X; public int Y; }

    private bool Inside(int x, int y)
    {
        if (x < 0 || y < 0 || x > W || y > H) return false;
        if (x >= R && x <= W - R) return true;
        if (y >= R && y <= H - R) return true;
        double cx = x < R ? R : W - R;
        double cy = y < R ? R : H - R;
        return ((x - cx) * (x - cx) + (y - cy) * (y - cy)) <= R * R;
    }

    public IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x0084)                            // WM_NCHITTEST
        {
            long lp = lParam.ToInt64();
            POINT p;
            p.X = (short)(lp & 0xFFFF);
            p.Y = (short)((lp >> 16) & 0xFFFF);
            ScreenToClient(hwnd, ref p);
            handled = true;
            if (Inside(p.X, p.Y)) return (IntPtr)1;    // HTCLIENT: the widget
            return (IntPtr)(-1);                       // HTTRANSPARENT: the desktop
        }
        return IntPtr.Zero;
    }
}
'@
}

# The Harness UI is its own desktop window, not a web page: the address it
# listens on answers 401 without a token, so a browser tab is the wrong target.
# Opening Harness therefore means bringing its window up, and only launching the
# app when it is not running at all.
if (-not ('HarnessWindow' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public class HarnessWindow
{
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr p);
    private delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    private static extern uint GetWindowThreadProcessIdPlain(IntPtr h, IntPtr unused);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();

    // The first visible titled window of a process by that name.
    public static IntPtr Find(string processName, IntPtr exclude)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            if (h == exclude || !IsWindowVisible(h)) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == 0) return true;
            try
            {
                if (!string.Equals(Process.GetProcessById((int)pid).ProcessName, processName, StringComparison.OrdinalIgnoreCase))
                    return true;
            }
            catch { return true; }
            StringBuilder sb = new StringBuilder(512);
            GetWindowTextW(h, sb, 512);
            if (sb.Length == 0) return true;        // helper windows have no title
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static bool Focus(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        if (IsIconic(h)) ShowWindow(h, 9);          // SW_RESTORE
        // Windows only lets the foreground process hand focus on, so borrow the
        // foreground thread's input queue for the moment of the call.
        uint fg = GetWindowThreadProcessIdPlain(GetForegroundWindow(), IntPtr.Zero);
        uint me = GetCurrentThreadId();
        AttachThreadInput(me, fg, true);
        bool ok = SetForegroundWindow(h);
        AttachThreadInput(me, fg, false);
        return ok;
    }

    // Bring the window to the top even when Windows refuses to hand it the
    // focus, which happens whenever the caller is not the foreground window.
    // Better a raised window without focus than a second copy of the app.
    public static void Raise(IntPtr h)
    {
        if (h == IntPtr.Zero) return;
        if (IsIconic(h)) ShowWindow(h, 9);          // SW_RESTORE
        ShowWindow(h, 5);                           // SW_SHOW
        SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0040);
    }
}
'@
}

function Open-Harness {
  $target = [HarnessWindow]::Find('DeepSeek Harness', $hwnd)
  if ($target -ne [IntPtr]::Zero) {
    if ([HarnessWindow]::Focus($target)) { Write-Log 'harness window raised'; return }
    # Focus can be refused when the widget is not the foreground window. Raise it
    # as far as we can and stop: the app is already running, so starting it again
    # would only risk a second copy of it.
    [HarnessWindow]::Raise($target)
    Write-Log 'harness window raised without focus'
    return
  }
  foreach ($exe in @(
      (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
      (Join-Path ${env:ProgramFiles} 'DeepSeek Harness\DeepSeek Harness.exe'))) {
    if (Test-Path $exe) {
      Write-Log "starting $exe"
      try { Start-Process $exe } catch { Write-Log ("start failed: " + $_.Exception.Message) }
      return
    }
  }
  Write-Log "fallback -> $HarnessUrl"
  try { Start-Process $HarnessUrl } catch { Write-Log ("open failed: " + $_.Exception.Message) }
}

$mouseHook = New-Object WidgetMouseHook
$mouseHook.W = $caseW
$mouseHook.H = $caseH
$mouseHook.R = $radius
$mouseHook.Target = $hwnd
$mouseHook.WpfWindow = $win

$mouseHook.OnMenu = [Action] {
  Write-Log 'menu'
  $mouseHook.Paused = $true                  # the menu owns the mouse from here
  $win.Dispatcher.BeginInvoke([Action] {
    try {
      $menu.PlacementTarget = $win
      $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::MousePoint
      $menu.IsOpen = $true
    } catch { }
  }) | Out-Null
}

# When the menu closes - an item was chosen, or the user clicked away - the
# widget takes the mouse back.
$menu.Add_Closed({
  Write-Log 'menu closed'
  $mouseHook.Paused = $false
})

$mouseHook.OnPress = [Action] { Write-Log 'press on case' }

$mouseHook.OnClick = [Action] {
  Write-Log 'click: open Harness'
  Open-Harness
}

$mouseHook.OnMoved = [Action] {
  $mouseHook.SyncWpfPosition()
  Write-Log ("drag ended: window=$($mouseHook.RectLeft),$($mouseHook.RectTop) moves=$($mouseHook.MovesSeen)")
  $pos = @{ left = [double]$mouseHook.RectLeft; top = [double]$mouseHook.RectTop } | ConvertTo-Json
  Set-Content -Path (Join-Path $Cache 'position.json') -Value $pos -Encoding UTF8
}

# Dragging runs on its own steady beat, well away from the mouse hook: the hook
# only records where the pointer is, this timer puts the window there. That is
# what keeps the widget glued to the pointer instead of juddering against it.
$script:dragTicks = 0
$dragTimer = New-Object System.Windows.Threading.DispatcherTimer
$dragTimer.Interval = [TimeSpan]::FromMilliseconds(15)
$dragTimer.Add_Tick({
  if ($mouseHook.Dragging) {
    try {
      $mouseHook.Place($mouseHook.CursorX, $mouseHook.CursorY)
      $script:dragTicks++
      if ($Debug -and ($script:dragTicks % 10) -eq 0) {
        Write-Log ("drag: cursor=$($mouseHook.CursorX),$($mouseHook.CursorY) window=$($mouseHook.RectLeft),$($mouseHook.RectTop) moves=$($mouseHook.MovesSeen)")
      }
    } catch { }
  } else {
    $script:dragTicks = 0
  }
})
$dragTimer.Start()

# The window answers the hit test so that clicks outside the case reach the
# desktop; the mouse itself is handled by the low-level hook above.
$hitHook = New-Object WidgetHitHook
$hitHook.W = $caseW
$hitHook.H = $caseH
$hitHook.R = $radius
$hitDelegate = [System.Delegate]::CreateDelegate([System.Windows.Interop.HwndSourceHook], $hitHook, 'Hook')
[void]$source.AddHook($hitDelegate)

$hookOk = $mouseHook.Install()
Write-Log ("mouse hook installed=$hookOk, case ${caseW}x${caseH} r=$radius")
$win.Add_Closed({ try { $mouseHook.Remove() } catch { } })

New-Item -ItemType Directory -Force -Path $Cache | Out-Null
Set-Content -Path $PidFile -Value $PID -Encoding ASCII

"Widget on the desktop: case ${caseW}x${caseH} DIP at $X,$Y (pid $PID) - $Url" | Write-Host

[System.Windows.Threading.Dispatcher]::Run()
