@echo off
echo Generazione manifest in corso...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_manifest.ps1"

echo.
pause


