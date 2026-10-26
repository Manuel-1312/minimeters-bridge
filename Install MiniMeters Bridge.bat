@echo off
setlocal
cd /d "%~dp0"
echo Installing MiniMeters Bridge...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
if errorlevel 1 (echo Install did not finish - read the message above.) else (echo Done. You can close this window.)
echo.
pause
