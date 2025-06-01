@echo off
echo 正在修复photo_manager插件...

set PLUGIN_PATH=%USERPROFILE%\AppData\Local\Pub\Cache\hosted\pub.dev\photo_manager-3.6.1\android\build.gradle

echo 备份原始文件...
copy "%PLUGIN_PATH%" "%PLUGIN_PATH%.bak"

echo 修改build.gradle文件...
echo. >> "%PLUGIN_PATH%"
echo dependencies { >> "%PLUGIN_PATH%"
echo     implementation "com.github.bumptech.glide:glide:4.15.1" >> "%PLUGIN_PATH%"
echo     annotationProcessor "com.github.bumptech.glide:compiler:4.15.1" >> "%PLUGIN_PATH%"
echo } >> "%PLUGIN_PATH%"

echo 修复完成！
pause 