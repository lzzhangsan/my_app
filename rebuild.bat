@echo off
echo 清理项目并重新编译...
cd /d %~dp0
flutter clean
flutter pub get
echo 删除build目录...
rmdir /s /q build
mkdir build
echo 运行应用...
flutter run
pause

