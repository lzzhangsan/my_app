@echo off
REM Stable Flutter debug run for physical Android devices.
REM Root cause of "Waiting for VM Service..." here: HTTP(S)_PROXY (e.g. 127.0.0.1:7890)
REM intercepts localhost VM Service / DDS traffic after install.

cd /d "%~dp0.."

set "ADB=C:\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" (
  where adb >nul 2>&1 && set "ADB=adb"
)

echo [1/4] Fixing NO_PROXY for Flutter VM Service...
set "NO_PROXY=localhost,127.0.0.1,::1,%NO_PROXY%"
REM Do NOT send Flutter/adb localhost traffic through Clash/V2Ray.
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="
set "ALL_PROXY="
set "all_proxy="

echo [2/4] Refreshing adb...
"%ADB%" start-server
"%ADB%" devices -l
"%ADB%" reverse --remove-all >nul 2>&1

echo [3/4] Launching Flutter (no-dds first for stable R / hot restart)...
echo Tip: keep this window open. Use capital R for hot restart, r for hot reload.
echo.

flutter run --no-dds
if errorlevel 1 (
  echo.
  echo Retrying with explicit VM service ports...
  "%ADB%" reverse tcp:8888 tcp:8888
  flutter run --no-dds --host-vmservice-port=8888 --device-vmservice-port=8888
)

echo.
pause
