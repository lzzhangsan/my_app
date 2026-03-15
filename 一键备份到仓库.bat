@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ========================================
echo   一键备份到 GitHub 仓库
echo ========================================
echo.

git add -A
if %errorlevel% neq 0 (
    echo [错误] git add 失败
    pause
    exit /b 1
)

git status --short
echo.

set /p msg="请输入本次提交说明 (直接回车则使用默认): "
if "%msg%"=="" set msg=备份 %date% %time:~0,5%

git commit -m "%msg%"
if %errorlevel% neq 0 (
    echo.
    echo [提示] 可能没有新的变更需要提交
    pause
    exit /b 0
)

echo.
echo 正在推送到远程仓库...
git push origin main
if %errorlevel% neq 0 (
    echo [错误] 推送失败，请检查网络或远程仓库配置
    pause
    exit /b 1
)

echo.
echo ========================================
echo   备份完成！
echo ========================================
pause
