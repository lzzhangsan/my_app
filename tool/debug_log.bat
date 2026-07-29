@echo off
setlocal EnableExtensions
chcp 65001 >nul
title my_app Debug Log

cd /d "%~dp0.."
if errorlevel 1 (
  echo [ERROR] Cannot open project root: "%~dp0.."
  goto :fail
)

set "FILTER=%~1"

echo.
echo Starting app log viewer...
if "%FILTER%"=="" (
  echo Showing all logs from the app process.
) else (
  echo Showing lines containing: %FILTER%
)
echo Press Ctrl+C to stop.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0debug_log.ps1" -Prefix "%FILTER%"
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
  echo [ERROR] Log viewer exited with code %ERR%.
  goto :fail
)

echo Log capture finished.
echo Press any key to close.
pause >nul
endlocal & exit /b 0

:fail
echo.
echo Press any key to close.
pause >nul
endlocal & exit /b 1
