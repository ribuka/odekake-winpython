@echo off
uv run --project "%~dp0." --no-dev python "%~dp0build_offline.py" %*
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
