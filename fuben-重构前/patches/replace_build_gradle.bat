@echo off
echo 正在替换photo_manager插件的build.gradle文件...

set PLUGIN_PATH=%USERPROFILE%\AppData\Local\Pub\Cache\hosted\pub.dev\photo_manager-3.6.1\android\build.gradle
set PATCH_PATH=%~dp0photo_manager_build.gradle

echo 插件路径: %PLUGIN_PATH%
echo 补丁路径: %PATCH_PATH%

echo 备份原始文件...
copy "%PLUGIN_PATH%" "%PLUGIN_PATH%.bak"

echo 替换build.gradle文件...
copy "%PATCH_PATH%" "%PLUGIN_PATH%"

echo 修复完成！
echo 按任意键继续...
pause > nul 