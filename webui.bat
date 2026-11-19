@echo off
rem Launches the HTML technician menu. webserver.ps1 self-elevates, so double-click is enough.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0webserver.ps1"
