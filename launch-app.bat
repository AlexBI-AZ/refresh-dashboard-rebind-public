@echo off
REM Opens the Control Panel in its own Edge app window.
REM The server console starts minimized; closing the app window stops the server.
start "Power BI Dashboard Control Panel - server" /min powershell -ExecutionPolicy Bypass -File "%~dp0server.ps1" -AppWindow
