<#
.SYNOPSIS
    Server-side script: installs the wallpaper sync on the defined client IPs over WinRM.

.DESCRIPTION
    For each IP in -Clients it connects remotely, pulls Install-Client.ps1 from GitHub and runs it,
    which registers the logon/hourly task on that client. Re-run any time to re-deploy, or use
    -RunNow to trigger a sync immediately on every client.

    Prerequisites on the clients: WinRM enabled (Enable-PSRemoting -Force) and an admin account.
    Workgroup (non-domain) setup: on this server first run
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.168.1.*,192.168.2.*' -Force

.EXAMPLE
    .\Deploy-FromServer.ps1 -RunNow
#>
[CmdletBinding()]
param(
    [string[]]$Clients = @('10.120.149.218', '10.120.149.126', '10.57.170.138'),
    [string]$RawBase   = 'https://raw.githubusercontent.com/Mohid105/wallpaper-sync/main',
    [pscredential]$Credential,
    [switch]$RunNow
)

if (-not $Credential) { $Credential = Get-Credential -Message 'Admin account on the clients' }

$results = foreach ($client in $Clients) {
    try {
        Invoke-Command -ComputerName $client -Credential $Credential -ErrorAction Stop `
            -ArgumentList $RawBase, $RunNow.IsPresent -ScriptBlock {
                param($RawBase, $RunNow)
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $tmp = Join-Path $env:TEMP 'Install-Client.ps1'
                Invoke-WebRequest -Uri "$RawBase/Install-Client.ps1" -UseBasicParsing -OutFile $tmp
                if ($RunNow) { & $tmp -RawBase $RawBase -RunNow } else { & $tmp -RawBase $RawBase }
                Remove-Item $tmp -Force
            }
        [pscustomobject]@{ Client = $client; Status = 'OK'; Detail = '' }
    } catch {
        [pscustomobject]@{ Client = $client; Status = 'FAILED'; Detail = $_.Exception.Message }
    }
}
$results | Format-Table -AutoSize
