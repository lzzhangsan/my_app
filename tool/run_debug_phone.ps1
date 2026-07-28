#Requires -Version 5.1
<#
  Stable phone debug for Vivo (and similar OEM phones):
  build -> adb install -> cold start (no auth codes) -> discover VM port -> flutter attach --no-dds

  Why bare "flutter run" breaks R:
  1) App installs/launches, but tool hangs on "Waiting for VM Service port..."
  2) Vivo filters the logcat line that contains the VM Service URL/token
  3) HTTP_PROXY=127.0.0.1:7890 (Clash) can also break localhost VM/DDS traffic
  Result: no "Flutter run key commands", so R does nothing.

  Usage:
    tool\run_debug_phone.bat
    tool\run_debug_phone.bat attach      # skip build/install
    tool\run_debug_phone.bat skipbuild   # reuse existing APK

  After "Flutter run key commands":
    r = hot reload, R = hot restart, q = quit
#>
param(
  [switch]$AttachOnly,
  [switch]$SkipBuild,
  [switch]$DryRun
)

$ErrorActionPreference = "Continue"
trap {
  Write-Host ""
  Write-Host "[FATAL] $($_.Exception.Message)" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
  if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor Yellow
    try { [void][Console]::ReadLine() } catch {}
  }
  exit 1
}

$DeviceId = "10CEB51267001CP"
$PackageName = "com.example.change_copy2"
$ActivityName = "$PackageName.MainActivity"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot
Write-Host "[run_debug_phone.ps1] ProjectRoot=$ProjectRoot"
Write-Host "[run_debug_phone.ps1] AttachOnly=$AttachOnly SkipBuild=$SkipBuild DryRun=$DryRun"

if ($DryRun) {
  Write-Host "[DryRun] Bat/PS1 launch OK. Exiting without adb/flutter." -ForegroundColor Green
  exit 0
}

function Write-Step($n, $msg) {
  Write-Host ""
  Write-Host "[$n] $msg" -ForegroundColor Cyan
}

function Clear-DebugProxy {
  foreach ($name in @(
      "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
      "ALL_PROXY", "all_proxy", "FTP_PROXY", "ftp_proxy"
    )) {
    Set-Item -Path "Env:$name" -Value "" -ErrorAction SilentlyContinue
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
  }
  $np = "localhost,127.0.0.1,::1,LOCALHOST"
  $env:NO_PROXY = $np
  $env:no_proxy = $np
}

function Stop-StaleFlutterDebug {
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
      Write-Host "  stop stale PID $($_.ProcessId)"
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
  Start-Sleep -Seconds 1
}

function Get-AdbPath {
  $candidates = @(
    "C:\Android\Sdk\platform-tools\adb.exe",
    "$env:ANDROID_SDK_ROOT\platform-tools\adb.exe",
    "$env:ANDROID_HOME\platform-tools\adb.exe",
    "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
  ) | Where-Object { $_ -and (Test-Path $_) }
  return $candidates | Select-Object -First 1
}

function Start-AppDebugNoAuth([string]$adb) {
  & $adb -s $DeviceId shell am force-stop $PackageName | Out-Null
  Start-Sleep -Milliseconds 500
  # disable-service-auth-codes: Vivo hides VM auth URL in logcat; port scan + attach needs no token
  & $adb -s $DeviceId shell am start -n "$PackageName/$ActivityName" `
    --ez enable-dart-profiling true `
    --ez enable-checked-mode true `
    --ez verify-entry-points true `
    --ez disable-service-auth-codes true | Out-Null
}

function Wait-AppPid([string]$adb, [int]$seconds = 20) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    $pidOf = (& $adb -s $DeviceId shell pidof $PackageName 2>$null | Out-String).Trim()
    if ($pidOf -match '^\d+') {
      return $pidOf
    }
    Start-Sleep -Milliseconds 400
  }
  return $null
}

function Find-VmServicePort([string]$adb, [string]$pidOf) {
  $uid = (& $adb -s $DeviceId shell "stat -c %u /proc/$pidOf" 2>$null | Out-String).Trim()
  if (-not ($uid -match '^\d+$')) {
    return $null
  }
  $tcp = & $adb -s $DeviceId shell "cat /proc/$pidOf/net/tcp" 2>$null
  $ports = New-Object System.Collections.Generic.List[int]
  foreach ($line in $tcp) {
    if ($line -match '^\s*\d+:\s+([0-9A-Fa-f]{8}):([0-9A-Fa-f]{4})\s+[0-9A-Fa-f]{8}:[0-9A-Fa-f]{4}\s+0A\s+\S+\s+\S+\s+\S+\s+(\d+)') {
      $ipHex = $Matches[1]
      $portHex = $Matches[2]
      $ownerUid = $Matches[3]
      if ($ownerUid -ne $uid) { continue }
      $port = [Convert]::ToInt32($portHex, 16)
      $b0 = [Convert]::ToInt32($ipHex.Substring(6, 2), 16)
      $b1 = [Convert]::ToInt32($ipHex.Substring(4, 2), 16)
      $b2 = [Convert]::ToInt32($ipHex.Substring(2, 2), 16)
      $b3 = [Convert]::ToInt32($ipHex.Substring(0, 2), 16)
      $ip = "$b0.$b1.$b2.$b3"
      if ($ip -eq '127.0.0.1') {
        $ports.Add($port) | Out-Null
      }
    }
  }
  if ($ports.Count -eq 0) { return $null }
  # Prefer a port that answers as Dart VM Service
  foreach ($port in $ports) {
    & $adb -s $DeviceId forward --remove ("tcp:$port") 2>$null | Out-Null
    & $adb -s $DeviceId forward ("tcp:$port") ("tcp:$port") 2>$null | Out-Null
    try {
      $resp = & curl.exe -sS -m 2 --noproxy "*" "http://127.0.0.1:$port/" 2>$null
      if ($resp -match 'Dart Development Service|VM Service|Isolate|missing or invalid authentication') {
        return $port
      }
      # HTTP 200 with empty/short body after disable-auth also OK
      if ($LASTEXITCODE -eq 0 -and $resp) {
        return $port
      }
    } catch {}
  }
  return $ports[0]
}

# --- 1) proxy ---
Write-Step "1/7" "Clear proxy so localhost / ::1 VM Service is not hijacked by Clash"
Clear-DebugProxy
Write-Host "  NO_PROXY=$env:NO_PROXY"

# --- 2) stale flutter ---
Write-Step "2/7" "Stop stale flutter run/attach (including hung Waiting for VM Service)"
Stop-StaleFlutterDebug

# --- 3) adb ---
$adb = Get-AdbPath
if (-not $adb) {
  Write-Host "adb.exe not found" -ForegroundColor Red
  exit 1
}

Write-Step "3/7" "Refresh adb / device"
& $adb start-server | Out-Null
& $adb forward --remove-all 2>$null | Out-Null
$devices = & $adb devices | Where-Object { $_ -match "\tdevice$" }
if (-not ($devices -match [regex]::Escape($DeviceId))) {
  Write-Host "Phone $DeviceId offline. Current:" -ForegroundColor Red
  & $adb devices -l
  exit 1
}
& $adb devices -l
# Best-effort: make OEM logcat less aggressive (helps plain flutter run too)
& $adb -s $DeviceId shell setprop log.tag I 2>$null | Out-Null
& $adb -s $DeviceId logcat -c 2>$null | Out-Null

$apk = Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-debug.apk"
$doBuild = -not $AttachOnly -and -not $SkipBuild
$doInstall = -not $AttachOnly

if ($doBuild) {
  Write-Step "4/7" "Build debug APK"
  & flutter build apk --debug
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed" -ForegroundColor Red
    exit $LASTEXITCODE
  }
  if (-not (Test-Path $apk)) {
    Write-Host "Missing $apk" -ForegroundColor Red
    exit 1
  }
} else {
  Write-Step "4/7" "Skip build"
  if ($doInstall -and -not (Test-Path $apk)) {
    Write-Host "Missing $apk. Run without -SkipBuild." -ForegroundColor Red
    exit 1
  }
}

if ($doInstall) {
  Write-Step "5/7" "Install APK"
  & $adb -s $DeviceId install -t -r -d $apk
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Install failed" -ForegroundColor Red
    exit $LASTEXITCODE
  }
} else {
  Write-Step "5/7" "Skip install"
}

Write-Step "6/7" "Cold start with disable-service-auth-codes + discover VM port"
Start-AppDebugNoAuth $adb
Start-Sleep -Seconds 2
$pidOf = Wait-AppPid $adb 20
if (-not $pidOf) {
  Write-Host "App process not found; still trying port discovery..." -ForegroundColor Yellow
} else {
  Write-Host "  App pid=$pidOf" -ForegroundColor Green
}

$vmPort = $null
$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline) {
  if (-not $pidOf) { $pidOf = Wait-AppPid $adb 2 }
  if ($pidOf) {
    $vmPort = Find-VmServicePort $adb $pidOf
    if ($vmPort) { break }
  }
  Start-Sleep -Milliseconds 800
}

if ($vmPort) {
  Write-Host "  VM Service port=$vmPort" -ForegroundColor Green
} else {
  Write-Host "  Could not discover VM port; attach may wait forever" -ForegroundColor Yellow
}

# Capture Android/Flutter output independently from `flutter attach`.
# Windows PowerShell Start-Transcript does not reliably include stdout from a
# native child process, while this PID-scoped logcat file remains tail-able.
$debugLogDir = Join-Path $ProjectRoot "debug_logs"
New-Item -ItemType Directory -Path $debugLogDir -Force | Out-Null
$androidLogPath = Join-Path $debugLogDir "android_app_latest.log"
$androidLogErrPath = Join-Path $debugLogDir "android_app_latest.err.log"
$androidLogProcess = $null
if ($pidOf) {
  Remove-Item -LiteralPath $androidLogPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $androidLogErrPath -Force -ErrorAction SilentlyContinue
  try {
    $androidLogProcess = Start-Process -FilePath $adb `
      -ArgumentList @("-s", $DeviceId, "logcat", "--pid=$pidOf", "-v", "time") `
      -RedirectStandardOutput $androidLogPath `
      -RedirectStandardError $androidLogErrPath `
      -WindowStyle Hidden `
      -PassThru
    Write-Host "  Android live log: $androidLogPath" -ForegroundColor Green
    Write-Host "  VS terminal view: Get-Content '$androidLogPath' -Wait -Tail 100" -ForegroundColor Green
  } catch {
    Write-Host "  Could not start PID-scoped logcat: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

# --- 7) attach ---
Write-Step "7/7" "flutter attach --no-dds (keep this window focused; then press R)"
Write-Host ""
Write-Host "  *** Keep this window open and focused ***" -ForegroundColor Yellow
Write-Host "  *** r = hot reload, R = hot restart, q = quit ***" -ForegroundColor Yellow
Write-Host "  *** Do NOT use bare: flutter run --verbose ***" -ForegroundColor DarkYellow
Write-Host ""

Clear-DebugProxy
& $adb -s $DeviceId forward --remove-all 2>$null | Out-Null

# Preserve the interactive attach window (including I/flutter diagnostics)
# without piping stdout, because a PowerShell pipeline would break r/R/q input.
$attachLogPath = Join-Path $debugLogDir "flutter_attach_latest.log"
$transcriptStarted = $false
try {
  New-Item -ItemType Directory -Path $debugLogDir -Force | Out-Null
  Start-Transcript -Path $attachLogPath -Force | Out-Null
  $transcriptStarted = $true
  Write-Host "  Attach log: $attachLogPath" -ForegroundColor Green
} catch {
  Write-Host "  Could not start attach transcript: $($_.Exception.Message)" -ForegroundColor Yellow
}

$attachArgs = @(
  "attach",
  "-d", $DeviceId,
  "--app-id", $PackageName,
  "--no-dds"
)
if ($vmPort) {
  $attachArgs += @("--debug-port", "$vmPort")
}

& flutter @attachArgs
$code = $LASTEXITCODE

if ($code -ne 0 -and (Test-Path $apk)) {
  Write-Host ""
  Write-Host "attach failed; fallback: flutter run --no-dds --disable-service-auth-codes ..." -ForegroundColor Yellow
  Clear-DebugProxy
  & $adb -s $DeviceId forward --remove-all 2>$null | Out-Null
  & flutter run --no-dds --disable-service-auth-codes `
    --use-application-binary="$apk" `
    -d $DeviceId
  $code = $LASTEXITCODE
}

if ($transcriptStarted) {
  try { Stop-Transcript | Out-Null } catch {}
}
if ($androidLogProcess -and -not $androidLogProcess.HasExited) {
  Stop-Process -Id $androidLogProcess.Id -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($code -eq 0) {
  Write-Host "Session ended normally." -ForegroundColor Green
} else {
  Write-Host "Session exited code=$code" -ForegroundColor Red
  Write-Host "Try: turn off Clash system proxy, unplug/replug USB, then run this script again." -ForegroundColor Yellow
  Write-Host "If another flutter run is stuck: close that terminal or re-run this script (it clears stale flutter)." -ForegroundColor Yellow
}
exit $code
