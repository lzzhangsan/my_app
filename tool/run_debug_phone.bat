@echo off
chcp 65001 >nul
title Flutter Debug Phone (stable R)
REM ============================================================
REM 稳定真机调试：热重载 R / 热重启需要「本窗口」保持连接。
REM 常见断连原因：
REM   1) HTTP(S)_PROXY(Clash 7890) 劫持了 localhost VM Service
REM   2) 旧的 flutter run / dart development-service 僵尸进程
REM   3) 用了 --device-vmservice-port 导致 port mismatch
REM 用法：双击本脚本；看到 "Flutter run key commands" 后再按 R
REM ============================================================

cd /d "%~dp0.."

set "ADB=C:\Android\Sdk\platform-tools\adb.exe"
if not exist "%ADB%" (
  where adb >nul 2>&1 && set "ADB=adb"
)

echo [1/5] 清除代理，避免 Clash 拦截 localhost...
set "HTTP_PROXY="
set "HTTPS_PROXY="
set "http_proxy="
set "https_proxy="
set "ALL_PROXY="
set "all_proxy="
set "NO_PROXY=localhost,127.0.0.1,::1,LOCALHOST"
set "no_proxy=%NO_PROXY%"

echo [2/5] 清理旧的 Flutter/Dart 调试进程...
powershell -NoProfile -Command ^
  "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(dart|flutter)\.exe$' -and $_.CommandLine -match 'flutter_tools\\.snapshot.*( run| attach)|development-service|devtools --no-launch' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

echo [3/5] 刷新 adb...
"%ADB%" start-server >nul
"%ADB%" forward --remove-all >nul 2>&1
"%ADB%" reverse --remove-all >nul 2>&1
"%ADB%" devices -l
"%ADB%" logcat -c >nul 2>&1

echo [4/5] 启动 Flutter（--no-dds --disable-service-auth-codes）...
echo.
echo   *** 请保持本窗口打开 ***
echo   *** 出现 "Flutter run key commands" 后：小写 r=热重载，大写 R=热重启 ***
echo.

flutter run --no-dds --disable-service-auth-codes -d 10CEB51267001CP
if errorlevel 1 (
  echo.
  echo 首次连接失败，正在重试（仍不固定 device-vmservice-port）...
  "%ADB%" forward --remove-all >nul 2>&1
  "%ADB%" reverse --remove-all >nul 2>&1
  flutter run --no-dds --disable-service-auth-codes -d 10CEB51267001CP
)

echo.
echo 会话已结束。若要再调试，请重新双击本脚本。
pause
