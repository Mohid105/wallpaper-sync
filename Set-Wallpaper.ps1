<#
.SYNOPSIS
    Downloads an image from an online link and sets it as the current user's wallpaper.

.DESCRIPTION
    Reads config.json (ImageUrl, Style, AllowedNetworks) from -ConfigUrl, falling back to the
    last cached copy when offline. If AllowedNetworks is non-empty, the wallpaper is only changed
    when one of this machine's IPv4 addresses falls inside one of those CIDR ranges
    (e.g. the subnets behind your two routers).

.EXAMPLE
    .\Set-Wallpaper.ps1 -ConfigUrl https://raw.githubusercontent.com/USER/REPO/main/config.json
#>
[CmdletBinding()]
param(
    [string]$ConfigUrl,
    [string]$WorkDir = (Join-Path $env:LOCALAPPDATA 'WallpaperSync')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$logFile    = Join-Path $WorkDir 'wallpaper.log'
$configFile = Join-Path $WorkDir 'config.json'

function Write-Log([string]$Message) {
    "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message | Add-Content -Path $logFile
    Write-Verbose $Message
}

function ConvertTo-UInt32([string]$Ip) {
    $bytes = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
    [Array]::Reverse($bytes)
    [BitConverter]::ToUInt32($bytes, 0)
}

function Test-InCidr([string]$Ip, [string]$Cidr) {
    $net, $len = $Cidr -split '/'
    $len  = if ($len) { [int]$len } else { 32 }
    $mask = if ($len -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $len)) }
    ((ConvertTo-UInt32 $Ip) -band $mask) -eq ((ConvertTo-UInt32 $net) -band $mask)
}

try {
    # --- load config (online first, cached copy as fallback) ---
    if ($ConfigUrl) {
        try {
            $json = (Invoke-WebRequest -Uri $ConfigUrl -UseBasicParsing -TimeoutSec 20).Content
            Set-Content -Path $configFile -Value $json -Encoding UTF8
        } catch {
            Write-Log "Could not fetch config ($($_.Exception.Message)); using cached copy."
        }
    }
    if (-not (Test-Path $configFile)) { throw 'No config available (offline and nothing cached).' }
    $config = Get-Content $configFile -Raw | ConvertFrom-Json

    # --- IP restriction ---
    if ($config.AllowedNetworks -and $config.AllowedNetworks.Count -gt 0) {
        $localIps = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object -ExpandProperty IPAddress
        $allowed = $false
        foreach ($ip in $localIps) {
            foreach ($cidr in $config.AllowedNetworks) {
                if (Test-InCidr $ip $cidr) { $allowed = $true }
            }
        }
        if (-not $allowed) {
            Write-Log "Skipped: local IPs ($($localIps -join ', ')) not in allowed networks."
            return
        }
    }

    # --- download image ---
    $ext = [IO.Path]::GetExtension(([Uri]$config.ImageUrl).AbsolutePath)
    if (-not $ext) { $ext = '.jpg' }
    $imageFile = Join-Path $WorkDir "wallpaper$ext"
    Invoke-WebRequest -Uri $config.ImageUrl -UseBasicParsing -OutFile $imageFile -TimeoutSec 60

    # --- set wallpaper ---
    $styles = @{
        Fill    = @(10, 0); Fit  = @(6, 0); Stretch = @(2, 0)
        Tile    = @(0, 1);  Center = @(0, 0); Span   = @(22, 0)
    }
    $style = if ($styles.ContainsKey([string]$config.Style)) { [string]$config.Style } else { 'Fill' }
    $desktopKey = 'HKCU:\Control Panel\Desktop'
    Set-ItemProperty -Path $desktopKey -Name WallpaperStyle -Value ([string]$styles[$style][0])
    Set-ItemProperty -Path $desktopKey -Name TileWallpaper  -Value ([string]$styles[$style][1])

    if (-not ('WallpaperApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class WallpaperApi {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    }
    # SPI_SETDESKWALLPAPER = 20; SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 3
    if (-not [WallpaperApi]::SystemParametersInfo(20, 0, $imageFile, 3)) {
        throw "SystemParametersInfo failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    Write-Log "Wallpaper set from $($config.ImageUrl) (style $style)."
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
