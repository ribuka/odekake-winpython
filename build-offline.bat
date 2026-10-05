@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-offline.ps1" %*
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
