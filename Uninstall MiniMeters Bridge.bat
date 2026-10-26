@echo off
setlocal
cd /d "%~dp0"
echo Removing MiniMeters Bridge...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
echo.
pause
