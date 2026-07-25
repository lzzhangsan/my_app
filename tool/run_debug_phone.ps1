#Requires -Version 5.1
<#
  稳定真机调试：build → adb install → 启动 → flutter attach
  避免「Installing 完成后 App 已开、但主机永远连不上 VM Service → 按 R 无效」。

  用法：双击 run_debug_phone.bat（或本脚本）
  看到 "Waiting for a connection" / "Flutter run key commands" 后再按：
    r = 热重载，R = 热重启，q = 退出
#>
$ErrorActionPreference = "Continue"
$DeviceId = "10CEB51267001CP"
$PackageName = "com.example.change_copy2"
$ActivityName = "$PackageName.MainActivity"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

function Write-Step($n, $msg) {
  Write-Host ""
  Write-Host "[$n] $msg" -ForegroundColor Cyan
}

# --- 1) 清代理：Clash 等会劫持 127.0.0.1 上的 VM Service ---
Write-Step "1/6" "清除代理，保证 localhost VM Service 直连"
$env:HTTP_PROXY = ""
$env:HTTPS_PROXY = ""
$env:http_proxy = ""
$env:https_proxy = ""
$env:ALL_PROXY = ""
$env:all_proxy = ""
$env:NO_PROXY = "localhost,127.0.0.1,::1,LOCALHOST"
$env:no_proxy = $env:NO_PROXY

# --- 2) 清掉卡住的旧调试会话（不杀无关 dart）---
Write-Step "2/6" "清理卡住的 flutter run / attach / development-service"
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -match '^(dart|flutter)\.exe$' -and
    $_.CommandLine -and
    (
      $_.CommandLine -match 'flutter_tools\.snapshot.*( run| attach)(\s|$)' -or
      $_.CommandLine -match 'development-service' -or
      $_.CommandLine -match 'devtools --no-launch'
    )
  } |
  ForEach-Object {
    Write-Host "  stop PID $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
Start-Sleep -Seconds 1

# --- 3) adb ---
$adbCandidates = @(
  "C:\Android\Sdk\platform-tools\adb.exe",
  "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe",
  "$env:ANDROID_HOME\platform-tools\adb.exe",
  "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
) | Where-Object { $_ -and (Test-Path $_) }
$adb = $adbCandidates | Select-Object -First 1
if (-not $adb) {
  Write-Host "找不到 adb.exe" -ForegroundColor Red
  exit 1
}

Write-Step "3/6" "刷新 adb / 设备"
& $adb start-server | Out-Null
# 只清 forward，保留 reverse 策略由 flutter attach 自己建；全清 reverse 有时反而导致刚连上又断
& $adb forward --remove-all 2>$null | Out-Null
$devices = & $adb devices | Where-Object { $_ -match "\tdevice$" }
if (-not ($devices -match [regex]::Escape($DeviceId))) {
  Write-Host "手机 $DeviceId 未在线。当前：" -ForegroundColor Red
  & $adb devices -l
  exit 1
}
& $adb devices -l
& $adb -s $DeviceId logcat -c 2>$null | Out-Null

# --- 4) 编译 ---
Write-Step "4/6" "编译 debug APK（失败则无法 attach）"
& flutter build apk --debug
if ($LASTEXITCODE -ne 0) {
  Write-Host "编译失败" -ForegroundColor Red
  exit $LASTEXITCODE
}
$apk = Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-debug.apk"
if (-not (Test-Path $apk)) {
  Write-Host "未找到 $apk" -ForegroundColor Red
  exit 1
}

# --- 5) 安装并冷启动（debug 包才会开 VM Service）---
Write-Step "5/6" "安装并冷启动 App（强制走 debug Observatory）"
& $adb -s $DeviceId install -t -r -d $apk
if ($LASTEXITCODE -ne 0) {
  Write-Host "安装失败" -ForegroundColor Red
  exit $LASTEXITCODE
}
& $adb -s $DeviceId shell am force-stop $PackageName | Out-Null
Start-Sleep -Milliseconds 400
& $adb -s $DeviceId shell am start -n "$PackageName/$ActivityName" | Out-Null
Start-Sleep -Seconds 2

# 等 App 进程起来，给 Observatory 一点启动时间
Write-Host "  等待 App 进程 / VM Service 就绪 ..."
$deadline = (Get-Date).AddSeconds(20)
$appReady = $false
while ((Get-Date) -lt $deadline) {
  $pidOf = (& $adb -s $DeviceId shell pidof $PackageName 2>$null | Out-String).Trim()
  if ($pidOf -match '^\d+') {
    $appReady = $true
    # 再留一秒让 VM Service 监听
    Start-Sleep -Seconds 1
    break
  }
  Start-Sleep -Milliseconds 500
}
if ($appReady) {
  Write-Host "  App 已在运行" -ForegroundColor Green
} else {
  Write-Host "  未检测到进程，仍继续 attach" -ForegroundColor Yellow
}

# --- 6) attach：这才是「按 R 生效」的交互会话 ---
Write-Step "6/6" "flutter attach（保持本窗口；出现 key commands 后按 R）"
Write-Host ""
Write-Host "  *** 请保持本窗口打开、并让窗口处于焦点 ***" -ForegroundColor Yellow
Write-Host "  *** 小写 r = 热重载，大写 R = 热重启，q = 退出 ***" -ForegroundColor Yellow
Write-Host ""

$attachArgs = @(
  "attach",
  "-d", $DeviceId,
  "--app-id", $PackageName,
  "--no-dds"
)

& flutter @attachArgs
$code = $LASTEXITCODE

if ($code -ne 0) {
  Write-Host ""
  Write-Host "attach 失败，回退尝试：flutter run --use-application-binary（跳过重编）..." -ForegroundColor Yellow
  & $adb -s $DeviceId forward --remove-all 2>$null | Out-Null
  & flutter run --no-dds `
    --use-application-binary="$apk" `
    -d $DeviceId
  $code = $LASTEXITCODE
}

Write-Host ""
if ($code -eq 0) {
  Write-Host "会话正常结束。" -ForegroundColor Green
} else {
  Write-Host "会话异常退出 code=$code。可再双击脚本重试。" -ForegroundColor Red
}
exit $code
