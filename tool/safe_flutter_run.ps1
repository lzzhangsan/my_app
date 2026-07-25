[CmdletBinding()]
param(
    [string]$DeviceId = "",
    [switch]$FlutterVerbose
)

$ErrorActionPreference = "Stop"
$packageName = "com.example.change_copy2"
$activityName = "$packageName.MainActivity"
$projectRoot = Split-Path -Parent $PSScriptRoot

function Stop-WithMessage {
    param([string]$Message, [int]$ExitCode = 1)
    Write-Host ""
    Write-Host $Message -ForegroundColor Red
    Write-Host "The installed app was NOT uninstalled. Its data remains untouched." -ForegroundColor Yellow
    exit $ExitCode
}

Set-Location $projectRoot

# Clash / system proxy often breaks localhost VM Service → R does nothing.
$env:HTTP_PROXY = ""
$env:HTTPS_PROXY = ""
$env:http_proxy = ""
$env:https_proxy = ""
$env:ALL_PROXY = ""
$env:all_proxy = ""
$env:NO_PROXY = "localhost,127.0.0.1,::1,LOCALHOST"
$env:no_proxy = $env:NO_PROXY

# A second flutter run can race the installer and also causes DDS conflicts.
$activeRuns = @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        $_.CommandLine -and
        $_.CommandLine -match 'flutter_tools\.snapshot.*\srun(\s|$)'
    }
)
if ($activeRuns.Count -gt 0) {
    $processIds = ($activeRuns | ForEach-Object ProcessId) -join ", "
    Stop-WithMessage "Another flutter run session is active (PID: $processIds). Stop it with q or Ctrl+C, then retry."
}

if ([string]::IsNullOrWhiteSpace($DeviceId)) {
    $deviceJson = (& flutter devices --machine | Out-String)
    if ($LASTEXITCODE -ne 0) {
        Stop-WithMessage "Unable to query Flutter devices."
    }
    $androidDevices = @(
        $deviceJson | ConvertFrom-Json | Where-Object {
            $_.targetPlatform -like 'android-*'
        }
    )
    if ($androidDevices.Count -ne 1) {
        Stop-WithMessage "Expected exactly one Android device, found $($androidDevices.Count). Pass -DeviceId explicitly."
    }
    $DeviceId = $androidDevices[0].id
}

$sdkCandidates = @(
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    "C:\Android\Sdk",
    "$env:LOCALAPPDATA\Android\Sdk"
) | Where-Object { $_ }
$adb = $null
foreach ($sdk in $sdkCandidates) {
    $candidate = Join-Path $sdk "platform-tools\adb.exe"
    if (Test-Path $candidate) {
        $adb = $candidate
        break
    }
}
if (-not $adb) {
    Stop-WithMessage "adb.exe was not found. Set ANDROID_SDK_ROOT or pass a valid Android SDK installation."
}

$buildArgs = @("build", "apk", "--debug")
if ($FlutterVerbose) {
    $buildArgs += "--verbose"
}
Write-Host "Building the debug APK..." -ForegroundColor Cyan
& flutter @buildArgs
if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "Flutter build failed."
}

$apkPath = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-debug.apk"
if (-not (Test-Path $apkPath)) {
    Stop-WithMessage "Debug APK was not created at $apkPath."
}

Write-Host "Installing safely on $DeviceId..." -ForegroundColor Cyan
Write-Host "If the phone installer is shown, approve installation. Opening Permissions may reject this attempt, but this script will preserve the existing app." -ForegroundColor Yellow
& $adb -s $DeviceId install -t -r -d $apkPath
if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "APK replacement was rejected or failed. Fix the reason and run this script again."
}

Write-Host "Starting the app..." -ForegroundColor Cyan
& $adb -s $DeviceId shell am force-stop $packageName | Out-Null
& $adb -s $DeviceId shell am start -n "$packageName/$activityName" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Stop-WithMessage "The APK was installed, but the app could not be started."
}

Write-Host "Attaching Flutter. Use r for hot reload, R for hot restart, and q to quit." -ForegroundColor Green
$attachArgs = @("attach", "-d", $DeviceId)
if ($FlutterVerbose) {
    $attachArgs += "--verbose"
}
& flutter @attachArgs
exit $LASTEXITCODE
