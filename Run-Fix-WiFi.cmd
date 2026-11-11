@echo off
REM Fix-WiFi launcher - double-click to run Fix-WiFi.ps1.
REM Bypasses the "running scripts is disabled on this system" error; the script asks for admin rights.
REM Options can be passed through, e.g.:  Run-Fix-WiFi.cmd -Match "MyHomeWiFi" -Hotspot "MyPhone"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-WiFi.ps1" %*
