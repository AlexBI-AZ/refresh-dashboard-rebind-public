@echo off
title Power BI Dashboard Control Panel
echo ==============================================
echo   Power BI Dashboard Control Panel
echo ==============================================
echo.
echo Starting server...
echo.

REM Start the server
powershell -ExecutionPolicy Bypass -Command ^
  $ErrorActionPreference='Continue'; ^
  ^& '%~dp0server.ps1'; ^
  Write-Host 'Server stopped.'; ^
  pause

echo.
echo Server exited.
pause
