#Requires -Version 5.1
<#
  Live Android/Flutter log viewer for my_app.

  - Finds adb without requiring it on PATH.
  - Uses the only connected device unless -DeviceId is supplied.
  - Restricts logcat to the app PID.
  - Shows either every app log or only lines containing -Prefix.
  - Saves the complete, unfiltered app log under debug_logs/.
  - Does not install/uninstall the app, clear app data, or stop Flutter.

  Examples:
    tool\debug_log.bat
    tool\debug_log.bat SMART_
    powershell -File tool\debug_log.ps1 -Prefix FB_DL
    powershell -File tool\debug_log.ps1 -NoClear
#>
param(
  [string]$Prefix = "",
  [string]$DeviceId = "",
  [string]$PackageName = "com.example.change_copy2",
  [switch]$NoClear,
  [switch]$CheckOnly,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $ProjectRoot "debug_logs"

function Get-AdbPath {
  $candidates = @(
    (Get-Command adb.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    "C:\Android\Sdk\platform-tools\adb.exe",
    $(if ($env:ANDROID_SDK_ROOT) { Join-Path $env:ANDROID_SDK_ROOT "platform-tools\adb.exe" }),
    $(if ($env:ANDROID_HOME) { Join-Path $env:ANDROID_HOME "platform-tools\adb.exe" }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe" })
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  return $candidates | Select-Object -First 1
}

function Get-ConnectedDevices([string]$Adb) {
  $lines = & $Adb devices
  return @(
    $lines |
      Where-Object { $_ -match '^([^\s]+)\s+device$' } |
      ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device$') { $Matches[1] }
      }
  )
}

$Adb = Get-AdbPath
if (-not $Adb) {
  throw "adb.exe was not found. Install Android platform-tools or set ANDROID_SDK_ROOT."
}

if ($DryRun) {
  Write-Host "[OK] Script loaded." -ForegroundColor Green
  Write-Host "Project: $ProjectRoot"
  Write-Host "adb: $Adb"
  Write-Host "Package: $PackageName"
  Write-Host "Prefix: $(if ($Prefix) { $Prefix } else { '<all app logs>' })"
  exit 0
}

& $Adb start-server | Out-Null
# Force array semantics. PowerShell otherwise unwraps a single result into a
# string, and `$ConnectedDevices[0]` becomes the first character of the ID.
$ConnectedDevices = @(Get-ConnectedDevices $Adb)

if ($DeviceId) {
  if ($ConnectedDevices -notcontains $DeviceId) {
    throw "Device '$DeviceId' is not connected. Connected devices: $($ConnectedDevices -join ', ')"
  }
} elseif ($ConnectedDevices.Count -eq 1) {
  $DeviceId = $ConnectedDevices[0]
} elseif ($ConnectedDevices.Count -eq 0) {
  throw "No authorized Android device is connected."
} else {
  throw "Multiple devices are connected. Run debug_log.ps1 with -DeviceId <id>. Devices: $($ConnectedDevices -join ', ')"
}

$PidText = (& $Adb -s $DeviceId shell pidof $PackageName 2>$null | Out-String).Trim()
if ($PidText -notmatch '^(\d+)') {
  throw "App '$PackageName' is not running. Open the app on the phone and try again."
}
$AppPid = $Matches[1]

if ($CheckOnly) {
  Write-Host "[OK] Device and app process detected." -ForegroundColor Green
  Write-Host "Device: $DeviceId"
  Write-Host "Package: $PackageName"
  Write-Host "PID: $AppPid"
  exit 0
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$SafePrefix = if ($Prefix) {
  ($Prefix -replace '[^A-Za-z0-9_-]', '_').Trim('_')
} else {
  "ALL"
}
if (-not $SafePrefix) { $SafePrefix = "FILTER" }

$SessionLog = Join-Path $LogDir "${Timestamp}_${SafePrefix}.log"
$LatestLog = Join-Path $LogDir "debug_log_latest.log"
$LatestPath = Join-Path $LogDir "debug_log_latest.path.txt"

Set-Content -LiteralPath $SessionLog -Value "" -Encoding UTF8
Set-Content -LiteralPath $LatestLog -Value "" -Encoding UTF8
Set-Content -LiteralPath $LatestPath -Value $SessionLog -Encoding UTF8

$DeviceLogPath = "files/codex_debug.log"
& $Adb -s $DeviceId shell run-as $PackageName ls $DeviceLogPath 2>$null | Out-Null
$UseAppFile = $LASTEXITCODE -eq 0

if (-not $UseAppFile -and -not $NoClear) {
  & $Adb -s $DeviceId logcat -c
}

Write-Host "Device : $DeviceId" -ForegroundColor Cyan
Write-Host "Package: $PackageName (PID $AppPid)" -ForegroundColor Cyan
Write-Host "View   : $(if ($Prefix) { "lines containing '$Prefix'" } else { 'all app logs' })" -ForegroundColor Cyan
Write-Host "Saved  : $SessionLog" -ForegroundColor Green
Write-Host "Latest : $LatestLog" -ForegroundColor Green
Write-Host "Source : $(if ($UseAppFile) { 'app debug file (Vivo-safe)' } else { 'Android logcat fallback' })" -ForegroundColor Green
Write-Host ""
Write-Host "Reproduce the issue once, then press Ctrl+C and tell the assistant: 操作完成" -ForegroundColor Yellow
Write-Host ""

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$SessionWriter = [System.IO.StreamWriter]::new($SessionLog, $true, $Utf8NoBom)
$LatestWriter = [System.IO.StreamWriter]::new($LatestLog, $true, $Utf8NoBom)
$SessionWriter.AutoFlush = $true
$LatestWriter.AutoFlush = $true

try {
  try {
    if ($UseAppFile) {
      $LogStream = {
        & $Adb -s $DeviceId exec-out run-as $PackageName tail -n 200 -f $DeviceLogPath
      }
    } else {
      $LogStream = {
        & $Adb -s $DeviceId logcat "--pid=$AppPid" -v time
      }
    }
    & $LogStream |
      ForEach-Object {
        $Line = [string]$_
        $SessionWriter.WriteLine($Line)
        $LatestWriter.WriteLine($Line)
        if (-not $Prefix -or $Line.IndexOf($Prefix, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
          $Line
        }
      }
  } finally {
    $SessionWriter.Dispose()
    $LatestWriter.Dispose()
  }
} finally {
  Write-Host ""
  Write-Host "Log saved: $SessionLog" -ForegroundColor Green
}
