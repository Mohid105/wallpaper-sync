# Wallpaper sync (GitHub → clients)

| File | Where it runs | Purpose |
|---|---|---|
| `Set-Wallpaper.ps1` | client | Downloads the image from the URL in `config.json` and sets it as the wallpaper |
| `config.json` | read by clients | `ImageUrl`, `Style`, `AllowedNetworks` (the subnets of your 2 routers) |
| `Install-Client.ps1` | client, once | Registers a scheduled task: pull latest script from GitHub + run it at **every logon** and **hourly** |
| `Deploy-FromServer.ps1` | server | Pushes `Install-Client.ps1` to the 4 client IPs over WinRM |

To change the wallpaper for everyone, edit `ImageUrl` in `config.json` and push. Clients pick it up at the next logon or hourly run.

## 1. Edit the placeholders
- `config.json`: set `ImageUrl` (any direct link to a jpg/png/bmp), and `AllowedNetworks` to the subnets behind router 1 and router 2.
- `Deploy-FromServer.ps1`: set `-Clients` (4 IPs) and `-RawBase`.
- `RawBase` is `https://raw.githubusercontent.com/<user>/<repo>/main`.

## 2. Upload to GitHub
Use a **public** repo so clients can fetch the raw links without a token. Only you should have push access, because clients execute whatever is in this repo.

```bash
cd wallpaper-sync
git init -b main
git add .
git commit -m "Wallpaper sync scripts"
git remote add origin https://github.com/<user>/<repo>.git
git push -u origin main
```

## 3a. Clients pull and run manually (PowerShell as Administrator)
```powershell
$base = 'https://raw.githubusercontent.com/<user>/<repo>/main'
irm "$base/Install-Client.ps1" -OutFile "$env:TEMP\Install-Client.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-Client.ps1" -RawBase $base -RunNow
```

## 3b. Server deploys to all 4 clients automatically
On each client, once: `Enable-PSRemoting -Force`. On the server:
```powershell
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '192.168.1.*,192.168.2.*' -Force   # workgroup only
.\Deploy-FromServer.ps1 -RunNow
```

## 3c. Group Policy (domain)
Best option if the clients are domain-joined.
1. Put `Install-Client.ps1` on `\\server\NETLOGON` (or `SYSVOL`).
2. GPMC → new GPO → **Computer Configuration → Policies → Windows Settings → Scripts → Startup → PowerShell Scripts**.
   Script: `\\server\NETLOGON\Install-Client.ps1`, parameters: `-RawBase https://raw.githubusercontent.com/<user>/<repo>/main`.
   It runs as SYSTEM at boot and registers the per-user logon task.
3. To limit it to defined IPs, either:
   - link the GPO to an OU containing only those 4 computers, or
   - use **Preferences** with item-level targeting → *IP Address Range*, or a WMI filter.
4. The task then runs at every logon on its own. `AllowedNetworks` in `config.json` is a second guard.

For a pure logon script instead, use **User Configuration → Policies → Windows Settings → Scripts → Logon** and point it at a copy of `Run.ps1` (created by the installer in `C:\ProgramData\WallpaperSync`).

Don't use the built-in "Desktop Wallpaper" GPO setting for this. It needs a local or UNC path, not a web link.

## Notes
- Wallpaper is per user, so the task runs as the logged-on user, not SYSTEM.
- Logs are in `%LOCALAPPDATA%\WallpaperSync\wallpaper.log` on each client.
- Clients that are offline use the last cached script and config.
- Uninstall: `Unregister-ScheduledTask -TaskName WallpaperSync -Confirm:$false`.
- If a user or GPO forces a wallpaper (Active Desktop / "Desktop Wallpaper" policy), that policy wins.
