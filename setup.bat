@echo off
REM Per-user setup for the Power BI Dashboard Control Panel. No admin rights needed.
REM Arguments are passed on, for example: setup.bat -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
