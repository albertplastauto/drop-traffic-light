@echo off
rem  Author: Albert Kadantsev
rem ============================================================
rem  Drop Traffic Light - remove the widget from the desktop.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0widget-host.ps1" -Stop
