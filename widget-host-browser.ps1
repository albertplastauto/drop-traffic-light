# ============================================================================
#  Drop Traffic Light - desktop widget host (Windows).
#  Author: Albert Kadantsev - developed with assistance from DeepSeek-V4.1-Flash
#
#  Runs index.html in its own browser window and turns that window into an icon
#  that sits on the desktop like a shortcut:
#    * drops the taskbar button and the Alt+Tab entry (WS_EX_TOOLWINDOW);
#    * clips the window to the case outline - a rounded rectangle with the same
#      0.24-of-width radius as border-radius in index.html - so nothing but the
#      case is visible and everything outside it is click-through;
#    * parks the icon in the top right corner of the screen.
#
#  Why the handshake: Chromium draws its own title bar INSIDE the client area,
#  so Win32 alone cannot tell how much of the client is browser chrome. In host
#  mode (?host=1&w=...) the page puts its real viewport size and device pixel
#  ratio into the window title, and the host derives the exact case rectangle
#  from that.
#
#  The widget is intentionally unclosable for interaction: no close button.
#  Remove it from the desktop with delete-widget.bat (or -Stop).
#
#  Usage:  start-widget.bat
#          widget-host.ps1 -Width 220 -X 60 -Y 60 -Topmost
# ============================================================================
param(
  [int]$Width = 150,          # icon width in CSS pixels
  [int]$X = -1,               # -1 = snap to the right edge of the screen
  [int]$Y = 32,
  [switch]$Topmost,           # keep above other windows
  [switch]$Stop               # remove the widget from the desktop
)

$ErrorActionPreference = 'Stop'

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Page       = Join-Path $Root 'index.html'
$ProfileDir = Join-Path $env:LOCALAPPDATA 'DropTrafficLight\profile'
$Title      = 'Drop Traffic Light'
$Ratio      = 46 / 54      # height / width - the case lies horizontally (54 : 46)
$Radius     = 0.24         # fraction of width - must match border-radius in index.html
$Margin     = 64           # px from the viewport's top/right edge (see index.html)
$Slack      = 320          # extra room for the browser chrome inside the window
$Bg         = 'ffffff'     # colour key: Chromium chrome colour, see below
$Inner      = 2            # clip inset, hides the antialiased edge of the case

if (-not ('Widget.Win32' -as [type])) {
  Add-Type -Namespace Widget -Name Win32 -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder s, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder s, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, int key, byte alpha, int flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int l, int t, int r, int b, int ew, int eh);
    [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}

[void][Widget.Win32]::SetProcessDPIAware()

# --- helpers ----------------------------------------------------------------
function Get-Browser {
  $c = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($p in $c) { if (Test-Path $p) { return $p } }
  return $null
}

# Widget processes are identified by their own profile directory, so another
# browser window can never be touched.
function Get-WidgetProcess {
  Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$ProfileDir*" }
}

function Find-WidgetWindow {
  param([int[]]$Pids)
  $script:found  = [IntPtr]::Zero
  $script:pids   = $Pids
  $script:prefix = $Title
  $cb = [Widget.Win32+EnumProc] {
    param([IntPtr]$h, [IntPtr]$l)
    if ([Widget.Win32]::IsWindowVisible($h)) {
      $cls = New-Object System.Text.StringBuilder 256
      [void][Widget.Win32]::GetClassName($h, $cls, 256)
      if ($cls.ToString() -like 'Chrome_WidgetWin*') {
        [uint32]$wpid = 0
        [void][Widget.Win32]::GetWindowThreadProcessId($h, [ref]$wpid)
        if ($script:pids -contains [int]$wpid) {
          $t = New-Object System.Text.StringBuilder 256
          [void][Widget.Win32]::GetWindowText($h, $t, 256)
          if ($t.ToString().StartsWith($script:prefix)) { $script:found = $h; return $false }
        }
      }
    }
    return $true
  }
  [void][Widget.Win32]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:found
}

# The page reports "Drop Traffic Light |<css-w>x<css-h>@<dpr>".
function Get-Viewport {
  param([IntPtr]$Hwnd)
  $t = New-Object System.Text.StringBuilder 256
  [void][Widget.Win32]::GetWindowText($Hwnd, $t, 256)
  $m = [regex]::Match($t.ToString(), '\|(\d+)x(\d+)@([\d.,]+)')
  if (-not $m.Success) { return $null }
  return @{
    w   = [int]$m.Groups[1].Value
    h   = [int]$m.Groups[2].Value
    dpr = [double]($m.Groups[3].Value -replace ',', '.')
  }
}

function Get-ClientSize {
  param([IntPtr]$Hwnd)
  $r = New-Object Widget.Win32+RECT
  [void][Widget.Win32]::GetClientRect($Hwnd, [ref]$r)
  return @{ w = $r.Right - $r.Left; h = $r.Bottom - $r.Top }
}

function Get-WindowSize {
  param([IntPtr]$Hwnd)
  $r = New-Object Widget.Win32+RECT
  [void][Widget.Win32]::GetWindowRect($Hwnd, [ref]$r)
  return @{ w = $r.Right - $r.Left; h = $r.Bottom - $r.Top; x = $r.Left; y = $r.Top }
}

# SetWindowRgn works in window coordinates, not client coordinates. Chromium
# keeps an invisible frame around its window, so the client origin has to be
# measured instead of assumed to be (0,0).
function Get-ClientOrigin {
  param([IntPtr]$Hwnd)
  $p = New-Object Widget.Win32+POINT
  $p.X = 0; $p.Y = 0
  [void][Widget.Win32]::ClientToScreen($Hwnd, [ref]$p)
  $w = Get-WindowSize -Hwnd $Hwnd
  return @{ x = $p.X - $w.x; y = $p.Y - $w.y }
}

# ============================== REMOVE ==============================
if ($Stop) {
  $procs = @(Get-WidgetProcess)
  foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  if ($procs.Count) { "Widget removed from the desktop ($($procs.Count) process(es) stopped)." }
  else { 'Widget is not running.' }
  return
}

# ============================== INSTALL ==============================
if (@(Get-WidgetProcess).Count -gt 0) { 'Widget is already on the desktop.'; return }

$browser = Get-Browser
if (-not $browser) { throw 'Neither Edge nor Chrome was found.' }

$CaseCssW = [Math]::Max(60, $Width)
$CaseCssH = [int][Math]::Round($CaseCssW * $Ratio)
$Url      = 'file:///' + ($Page -replace '\\', '/') + "?host=1&w=$CaseCssW&m=$Margin&bg=$Bg"

# A colour key makes every pixel of the chrome colour transparent, so the window
# itself needs no particular size - only enough room for the case plus margin.
$WinW = $CaseCssW + 2 * $Margin + $Slack
$WinH = $CaseCssH + 2 * $Margin + $Slack

if ($X -lt 0) { $X = [Widget.Win32]::GetSystemMetrics(0) - $CaseCssW - 32 }
if ($Y -lt 0) { $Y = 32 }

New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null

Start-Process -FilePath $browser -ArgumentList @(
  "--app=$Url",
  "--user-data-dir=$ProfileDir",
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-translate',
  '--lang=en-US',
  '--disable-features=Translate,TranslateUI,MediaRouter',
  '--disable-session-crashed-bubble',
  '--hide-crash-restore-bubble',
  "--window-size=$WinW,$WinH",
  "--window-position=$([Math]::Max(0, $X - 200)),$([Math]::Max(0, $Y - 100))"
) | Out-Null

$deadline = (Get-Date).AddSeconds(30)
$hwnd = [IntPtr]::Zero
while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
  $pids = @(Get-WidgetProcess | Select-Object -ExpandProperty ProcessId)
  if ($pids.Count -eq 0) { continue }
  $hwnd = Find-WidgetWindow -Pids $pids
}
if ($hwnd -eq [IntPtr]::Zero) { throw 'The widget window did not appear.' }

# --- drop the OS frame and the taskbar button -------------------------------
$GWL_STYLE, $GWL_EXSTYLE = -16, -20
$WS_CAPTION    = 0x00C00000
$WS_THICKFRAME = 0x00040000
$WS_SYSMENU    = 0x00080000
$WS_MINMAX     = 0x00030000
$WS_POPUP      = 0x80000000
$WS_EX_TOOLWIN = 0x00000080
$WS_EX_LAYERED = 0x00080000
$LWA_COLORKEY  = 0x00000001
$SWP_NOSIZE, $SWP_NOMOVE, $SWP_NOZORDER, $SWP_FRAMECHANGED, $SWP_SHOWWINDOW = 0x0001, 0x0002, 0x0004, 0x0020, 0x0040
$HWND_TOPMOST = [IntPtr](-1)

$style = [Widget.Win32]::GetWindowLong($hwnd, $GWL_STYLE)
$style = $style -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_SYSMENU -bor $WS_MINMAX))
$style = $style -bor $WS_POPUP
[void][Widget.Win32]::SetWindowLong($hwnd, $GWL_STYLE, $style)

$ex = [Widget.Win32]::GetWindowLong($hwnd, $GWL_EXSTYLE)
[void][Widget.Win32]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($ex -bor $WS_EX_TOOLWIN))

[void][Widget.Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $X, $Y + 200, $WinW, $WinH,
  ($SWP_NOZORDER -bor $SWP_FRAMECHANGED -bor $SWP_SHOWWINDOW))

# --- wait for the page to report its viewport -------------------------------
$vp = $null
$deadline = (Get-Date).AddSeconds(20)
while ($null -eq $vp -and (Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
  $vp = Get-Viewport -Hwnd $hwnd
}
if ($null -eq $vp) { throw 'The page never reported its viewport size.' }
if ($vp.dpr -le 0) { $vp.dpr = 1 }

# --- where the case actually is ---------------------------------------------
# The page pins the case to the top-right corner of its viewport ($Margin from
# both edges) and reports the viewport it ended up with, so the case rectangle
# can be derived exactly - no guessing at browser chrome.
$cur = Get-Viewport -Hwnd $hwnd
if ($null -ne $cur) { $vp = $cur }
if ($vp.dpr -le 0) { $vp.dpr = 1 }

$co = Get-ClientOrigin -Hwnd $hwnd
$cl = Get-ClientSize -Hwnd $hwnd

$vpW = [int][Math]::Round($vp.w * $vp.dpr)
$vpH = [int][Math]::Round($vp.h * $vp.dpr)
$vpX = [Math]::Max(0, [int][Math]::Round(($cl.w - $vpW) / 2))
$vpY = [Math]::Max(0, $cl.h - $vpH)

$margin = [int][Math]::Round($Margin * $vp.dpr)

# The case is min(requested, viewport) - the same rule the page applies - so the
# region can never reach into unpainted space around the viewport. It sits in the
# top-right corner of the viewport, where the page pinned it.
$caseW = [Math]::Min([int][Math]::Round($CaseCssW * $vp.dpr), [Math]::Min($vpW, [int][Math]::Round($vpH * (1 / $Ratio))))
$caseH = [int][Math]::Round($caseW * $Ratio)
$caseX = $vpX + [Math]::Max(0, $vpW - $margin - $caseW)
$caseY = $vpY + $margin

# --- clip the window to the case outline ------------------------------------
# The clip sits a couple of pixels inside the case, so the antialiased edge of
# the case (which blends towards the page background) never reaches the screen.
# Everything below is in window coordinates: client origin + case offset.
$rgnX = $co.x + $caseX + $Inner
$rgnY = $co.y + $caseY + $Inner
$rgnW = [Math]::Max(8, $caseW - 2 * $Inner)
$rgnH = [Math]::Max(8, $caseH - 2 * $Inner)
$rad = [int][Math]::Round($rgnW * $Radius)
$rgn = [Widget.Win32]::CreateRoundRectRgn($rgnX, $rgnY, $rgnX + $rgnW + 1, $rgnY + $rgnH + 1, 2 * $rad, 2 * $rad)
[void][Widget.Win32]::SetWindowRgn($hwnd, $rgn, $true)

# --- colour key: makes the browser chrome and the page background vanish -----
# Chromium paints its own title bar, its window background and the area around
# the web viewport in the theme colour; a window region does not clip that.
# Keying that exact colour out removes all of it, while the case - saturated
# green, yellow, red or turquoise - never contains it.
$key = [Convert]::ToInt32($Bg.Substring(4, 2), 16) -bor
       ([Convert]::ToInt32($Bg.Substring(2, 2), 16) -shl 8) -bor
       ([Convert]::ToInt32($Bg.Substring(0, 2), 16) -shl 16)      # COLORREF 0x00BBGGRR
$ex = [Widget.Win32]::GetWindowLong($hwnd, $GWL_EXSTYLE)
[void][Widget.Win32]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($ex -bor $WS_EX_LAYERED))
if (-not [Widget.Win32]::SetLayeredWindowAttributes($hwnd, $key, 0, $LWA_COLORKEY)) {
  throw 'Could not set the colour key on the widget window.'
}

# --- place the case itself at the requested spot on screen ------------------
$winX = $X - ($co.x + $caseX)
$winY = $Y - ($co.y + $caseY)
$ws = Get-WindowSize -Hwnd $hwnd

[void][Widget.Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $winX, $winY, 0, 0,
  ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_SHOWWINDOW))
if ($Topmost) {
  [void][Widget.Win32]::SetWindowPos($hwnd, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE))
}

"Widget on the desktop: case ${caseW}x${caseH} px at $X,$Y (viewport $($vp.w)x$($vp.h) CSS, dpr $($vp.dpr), window at $winX,$winY size $($ws.w)x$($ws.h), colour key #$Bg)"
