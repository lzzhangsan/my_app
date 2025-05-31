@echo off
echo 创建项目副本到纯ASCII路径...

:: 创建目标目录
mkdir "D:\flutter_clean_path" 2>nul

:: 创建排除文件列表
echo build\ > excluded_dirs.txt
echo .dart_tool\ >> excluded_dirs.txt
echo .idea\ >> excluded_dirs.txt
echo .gradle\ >> excluded_dirs.txt

:: 复制项目文件（除了build、.dart_tool等大型生成目录）
echo 正在复制项目文件...
xcopy "D:\app\my_flutter_app -2" "D:\flutter_clean_path" /E /H /C /I /Y /EXCLUDE:excluded_dirs.txt

echo 项目已复制到 D:\flutter_clean_path
echo.
echo 请切换到新目录运行Flutter命令:
echo cd /d D:\flutter_clean_path
echo flutter run
