@echo off
chcp 65001 >nul
title Flutter Debug Phone (stable R)
REM ============================================================
REM 稳定真机调试（修复：安装成功但按 R 无效）
REM
REM 根因：flutter run 在 Installing 后经常连不上手机上的 Dart VM Service，
REM       窗口停在 Installing / 无 "Flutter run key commands"，按 R 无效。
REM 做法：改为 编译 → adb 安装 → 冷启动 → flutter attach（交互会话）。
REM
REM 用法：双击本脚本或桌面快捷方式；
REM       看到 key commands / Waiting for a connection 成功后再按 R。
REM ============================================================

cd /d "%~dp0"

echo.
echo 启动稳定调试会话（build + install + attach）...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_debug_phone.ps1"
set "ERR=%ERRORLEVEL%"

echo.
if not "%ERR%"=="0" (
  echo 若仍失败：1^) 确认手机仍用 USB 调试  2^) 关掉 Clash 系统代理  3^) 再双击本脚本
)
echo 会话已结束。按任意键关闭窗口。
pause >nul
exit /b %ERR%
