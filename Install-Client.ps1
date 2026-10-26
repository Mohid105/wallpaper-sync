<#
.SYNOPSIS
    Run ONCE per client (as Administrator). Sets up automatic wallpaper pulling from GitHub.

.DESCRIPTION
    Creates C:\ProgramData\WallpaperSync\Run.ps1, which on every run pulls the latest
    Set-Wallpaper.ps1 from GitHub and executes it. Registers a scheduled task that runs
    Run.ps1 in the context of whichever user logs on (any member of BUILTIN\Users), at logon
    and then hourly. Wallpaper is a per-user setting, so it must run as the user, not SYSTEM.
    The IP restriction lives in config.json (AllowedNetworks), so clients outside those
    subnets do nothing.

.EXAMPLE
    .\Install-Client.ps1 -RawBase https://raw.githubusercontent.com/USER/REPO/main
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RawBase,
    [string]$TaskName = 'WallpaperSync',
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this script as Administrator.' }

$RawBase = $RawBase.TrimEnd('/')
$dir = Join-Path $env:ProgramData 'WallpaperSync'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$runner = @'
$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = '__RAWBASE__'
$dir  = Join-Path $env:ProgramData 'WallpaperSync'
$new  = Join-Path $dir 'Set-Wallpaper.ps1.new'
$main = Join-Path $dir 'Set-Wallpaper.ps1'
# pull the latest script from GitHub; keep the cached copy if offline
Invoke-WebRequest -Uri "$base/Set-Wallpaper.ps1" -UseBasicParsing -OutFile $new -TimeoutSec 20
if ((Test-Path $new) -and (Get-Item $new).Length -gt 0) { Move-Item $new $main -Force }
if (Test-Path $main) { & $main -ConfigUrl "$base/config.json" }
'@ -replace '__RAWBASE__', $RawBase
Set-Content -Path (Join-Path $dir 'Run.ps1') -Value $runner -Encoding UTF8

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\Run.ps1`"")
$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn
    New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
)
# S-1-5-32-545 = BUILTIN\Users: runs as each interactive user, no elevation
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Task '$TaskName' registered. Wallpaper will sync at every logon and hourly."

if ($RunNow) { Start-ScheduledTask -TaskName $TaskName }
