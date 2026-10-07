@echo off
rem  Author: Albert Kadantsev
rem ============================================================
rem  Drop Traffic Light - put the widget on the desktop.
rem  A frameless, transparent icon: no title bar, no taskbar button.
rem  Options: -Width 220  -X 40 -Y 40  -Topmost
rem ============================================================
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0widget-host.ps1" %*
