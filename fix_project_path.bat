@echo off
setlocal enabledelayedexpansion
chcp 65001 > nul

echo ======================================
echo 开始将Flutter项目复制到纯ASCII路径解决编译问题
echo ======================================

:: 定义目标目录
set "TARGET_DIR=D:\flutter_clean_project"

:: 创建目标目录
if exist "%TARGET_DIR%" (
    echo 目标目录已存在，将先清理...
    rd /s /q "%TARGET_DIR%"
)

echo 创建新的目标目录...
mkdir "%TARGET_DIR%"

echo 正在复制项目文件到纯ASCII路径...
:: 直接复制当前目录到目标目录，不使用排除文件
xcopy "D:\app\my_app" "%TARGET_DIR%" /E /H /C /I /Y

:: 检查复制是否成功
if %ERRORLEVEL% NEQ 0 (
    echo 复制文件时出错！
    goto :end
)

echo 项目已成功复制到: %TARGET_DIR%
echo.

:: 进入新目录并清理Flutter项目
echo 正在进入新目录并清理Flutter项目...
cd /d "%TARGET_DIR%"
flutter clean
flutter pub get

echo ======================================
echo 复制完成！现在请在新目录中构建和运行项目：
echo %TARGET_DIR%
echo 使用命令：flutter run
echo ======================================

:end
pause
