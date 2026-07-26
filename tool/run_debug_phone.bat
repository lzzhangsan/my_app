@echo off
setlocal EnableExtensions
chcp 65001 >nul
title Flutter Debug Phone (stable R)

REM ============================================================
REM Stable phone debug (fix: install OK but R does nothing)
REM
REM Root cause from flutter run --verbose log:
REM   After install/start, tool hangs at
REM   "Waiting for VM Service port to be available..."
REM   Never prints "Flutter run key commands" so R is dead.
REM
REM Why on this PC/phone:
REM   1) Vivo filters logcat VM Service URL/token
REM   2) Clash HTTP_PROXY=127.0.0.1:7890 can hijack localhost DDS/VM
REM   3) A hung flutter run may hold the session
REM
REM Fix path:
REM   clear proxy -> stop stale flutter -> build/install ->
REM   cold start with disable-service-auth-codes ->
REM   discover VM port -> flutter attach --debug-port --no-dds
REM
REM Usage:
REM   Double-click this file / desktop shortcut
REM   tool\run_debug_phone.bat
REM   tool\run_debug_phone.bat attach      = reattach only
REM   tool\run_debug_phone.bat skipbuild   = reuse APK
REM   tool\run_debug_phone.bat dryrun      = launch check only
REM ============================================================

echo.
echo [run_debug_phone] Starting...
echo [run_debug_phone] Script: %~f0
echo [run_debug_phone] Args: %*

REM Always go to repo root (parent of tool\), no matter where launched from
cd /d "%~dp0.."
if errorlevel 1 (
  echo [ERROR] Cannot cd to repo root: "%~dp0.."
  goto :fail
)
echo [run_debug_phone] Repo root: %CD%

set "PS1=%~dp0run_debug_phone.ps1"
if not exist "%PS1%" (
  echo [ERROR] Missing PowerShell script: "%PS1%"
  goto :fail
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] powershell.exe not found on PATH.
  echo         Install Windows PowerShell or fix PATH, then retry.
  goto :fail
)

set "MODE=full"
set "PSARGS="
if /i "%~1"=="dryrun" (
  set "MODE=dryrun"
  set "PSARGS=-DryRun"
) else if /i "%~1"=="attach" (
  set "MODE=attach"
  set "PSARGS=-AttachOnly"
) else if /i "%~1"=="skipbuild" (
  set "MODE=skipbuild"
  set "PSARGS=-SkipBuild"
)

echo [run_debug_phone] Mode: %MODE%
echo [run_debug_phone] Launching PowerShell with -ExecutionPolicy Bypass ...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PSARGS%
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
  echo [ERROR] PowerShell exited with code %ERR%
  echo.
  echo If it still fails:
  echo   1^) Turn off Clash system proxy
  echo   2^) Confirm USB debugging authorized
  echo   3^) Run again: tool\run_debug_phone.bat
  echo   4^) Or reattach: tool\run_debug_phone.bat attach
  goto :fail
)

echo Session finished OK.
echo Press any key to close.
pause >nul
endlocal & exit /b 0

:fail
echo.
echo Session failed. Window will stay open so you can read the error.
echo Press any key to close.
pause >nul
endlocal & exit /b 1
