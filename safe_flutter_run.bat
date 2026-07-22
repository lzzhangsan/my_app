@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tool\safe_flutter_run.ps1" %*
exit /b %ERRORLEVEL%
