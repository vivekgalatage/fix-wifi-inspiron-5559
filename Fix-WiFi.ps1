<#
.SYNOPSIS
  Fix-WiFi.ps1 - Windows 10/11 Wi-Fi diagnostic and repair script.

.DESCRIPTION
  Built for the Dell Inspiron 5559 (Intel Dual Band Wireless-AC 3160 / 3165), but works on
  most Windows 10/11 laptops. Targets the common case "my home Wi-Fi is not in the list,
  but other networks and other devices are fine" - typically caused by an old Intel driver
  that cannot see Wi-Fi 6 (802.11ax) routers.

  It collects a full report, then offers fixes one by one (Y/N), including installing a
  newer Wi-Fi driver from a local "Driver" folder or from Windows Update (over a phone
  hotspot), and backing up the working driver for next time.

  HOW TO RUN
    Double-click  Run-Fix-WiFi.cmd  (same folder). It asks for admin rights itself.
    Or:  powershell -ExecutionPolicy Bypass -File ".\Fix-WiFi.ps1" -Match "MyWiFi"

.PARAMETER Match
  Part of the name of the Wi-Fi network you cannot see. If omitted, the script asks.
.PARAMETER Hotspot
  Name of a saved hotspot / network to use for downloading a driver. Default: ask.
.PARAMETER Auto
  Apply the default answer to every question without asking.
.PARAMETER NoFix
  Diagnose only, change nothing.
.PARAMETER AllowDriverUpdates
  Undo the "stop Windows Update from replacing drivers" setting this script can apply, then exit.

.NOTES
  Reports are saved on the Desktop and next to this script. They contain your network names,
  MAC address and user name - redact them before posting publicly.
  Provided as-is, use at your own risk; see LICENSE.
#>
#Requires -Version 5.1
param(
    [string]$Match   = '',
    [string]$Hotspot = '',
    [switch]$Auto,
    [switch]$NoFix,
    [switch]$AllowDriverUpdates
)

$ErrorActionPreference = 'Continue'
$GoodIntelLegacy = [version]'18.33.17.1'     # fixed driver for AC-3160 / 7260 / 7265(C)

# ---------------------------------------------------------------- self-elevate
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    if ($Match)   { $argList += @('-Match', "`"$Match`"") }
    if ($AllowDriverUpdates) { $argList += '-AllowDriverUpdates' }
    if ($Hotspot) { $argList += @('-Hotspot', "`"$Hotspot`"") }
    if ($Auto)    { $argList += '-Auto' }
    if ($NoFix)   { $argList += '-NoFix' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------- undo option
$WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
if ($AllowDriverUpdates) {
    Remove-ItemProperty -Path $WuPolicyKey -Name ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue
    Write-Host 'Windows Update is allowed to install drivers again.' -ForegroundColor Green
    Read-Host 'Press Enter to close'
    exit
}

# ---------------------------------------------------------------- helpers
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not (Test-Path $desktop)) { $desktop = $env:USERPROFILE }
$report  = Join-Path $desktop "WiFi-Report-$stamp.txt"
Start-Transcript -Path $report -Force | Out-Null

$Findings   = New-Object System.Collections.Generic.List[string]
$Changes    = New-Object System.Collections.Generic.List[string]
$NeedReboot = $false
$LocationBlocked = $false
if (-not $Match -and -not $Auto) {
    Write-Host ''
    Write-Host '  Which Wi-Fi network is missing? Type part of its name (as shown on your other devices).' -ForegroundColor Cyan
    $Match = ([string](Read-Host '  >> Network name (Enter = general check only)')).Trim()
}
$HaveTarget = [bool]$Match
$MatchRx    = if ($HaveTarget) { [regex]::Escape($Match) } else { '(?!)' }   # (?!) never matches

function Section([string]$t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}
function Show($obj)          { Write-Host (($obj | Out-String).TrimEnd()) }
function Finding([string]$t) { $Findings.Add($t); Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Ok([string]$t)      { Write-Host "  [OK] $t" -ForegroundColor Green }
function Info([string]$t)    { Write-Host "  $t" }
function Changed([string]$t) { $Changes.Add($t); Write-Host "  [FIXED] $t" -ForegroundColor Green }
function Ask([string]$q, [bool]$default = $true) {
    if ($NoFix) { return $false }
    if ($Auto)  { return $default }
    $hint = if ($default) { '[Y/n]' } else { '[y/N]' }
    $r = Read-Host "  >> $q $hint"
    if ([string]::IsNullOrWhiteSpace($r)) { return $default }
    return ($r -match '^[Yy]')
}

function Find-WifiAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11' } |
        Select-Object -First 1
}
function Get-Ver([string]$s) { try { return [version]$s } catch { return $null } }

function Test-IntelCard($a)   { return ($a -and $a.InterfaceDescription -match 'Intel') }
function Test-LegacyIntel($a) { return ((Test-IntelCard $a) -and $a.InterfaceDescription -match '\b(3160|7260|7265)\b') }

function Test-DriverNeedsUpdate($a) {
    if (-not (Test-LegacyIntel $a)) { return $false }
    $v = Get-Ver $a.DriverVersion
    return [bool]($v -and $v -lt $GoodIntelLegacy)
}

# After a driver install the adapter disappears for a few seconds - wait for it to come back
function Wait-WifiAdapter([int]$seconds = 40) {
    for ($i = 0; $i -lt $seconds; $i += 2) {
        $x = Find-WifiAdapter
        if ($x -and $x.Status -ne 'Not Present') { return $x }
        Start-Sleep -Seconds 2
    }
    return (Find-WifiAdapter)
}

function Restart-Wifi($a) {
    Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    Enable-NetAdapter  -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 8
}

function Test-Internet {
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8
        return ($r.Content -match 'Microsoft Connect Test')
    } catch { return $false }
}

# Force a fresh Wi-Fi scan through the native WLAN API
$csharp = @'
using System;
using System.Runtime.InteropServices;
public static class WlanScanner {
    [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint v, IntPtr r, out uint neg, out IntPtr h);
    [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
    [DllImport("wlanapi.dll")] static extern int WlanEnumInterfaces(IntPtr h, IntPtr r, out IntPtr list);
    [DllImport("wlanapi.dll")] static extern int WlanScan(IntPtr h, ref Guid g, IntPtr ssid, IntPtr ie, IntPtr r);
    [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
    public static int ScanAll() {
        IntPtr h; uint neg;
        if (WlanOpenHandle(2, IntPtr.Zero, out neg, out h) != 0) return -1;
        int ok = 0; IntPtr list;
        if (WlanEnumInterfaces(h, IntPtr.Zero, out list) == 0) {
            int n = Marshal.ReadInt32(list);
            for (int i = 0; i < n; i++) {
                IntPtr item = new IntPtr(list.ToInt64() + 8 + i * 532);
                Guid g = (Guid)Marshal.PtrToStructure(item, typeof(Guid));
                if (WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) == 0) ok++;
            }
            WlanFreeMemory(list);
        }
        WlanCloseHandle(h, IntPtr.Zero);
        return ok;
    }
}
'@
function Invoke-WifiScan {
    try {
        if (-not ('WlanScanner' -as [type])) { Add-Type -TypeDefinition $csharp -ErrorAction Stop }
        [void][WlanScanner]::ScanAll()
        Info 'Scanning for networks (8 seconds)...'
        Start-Sleep -Seconds 8
    } catch {
        Info "(Could not trigger scan: $($_.Exception.Message) - using cached list)"
        Start-Sleep -Seconds 3
    }
}

function Get-Networks {
    $raw  = netsh wlan show networks mode=bssid
    if (($raw -join ' ') -match 'location (permission|services)') { $script:LocationBlocked = $true }
    $list = @()
    $cur  = $null
    foreach ($line in $raw) {
        if ($line -match '^SSID\s+\d+\s*:\s*(.*)$') {
            $name = $matches[1].Trim()
            if ($name -eq '') { $name = '<hidden>' }
            $cur = [pscustomobject]@{ SSID = $name; Auth = ''; Signal = 0; Channels = @(); Radio = @() }
            $list += $cur
        } elseif ($cur) {
            if     ($line -match '^\s+Authentication\s*:\s*(.+)$') { $cur.Auth = $matches[1].Trim() }
            elseif ($line -match '^\s+Signal\s*:\s*(\d+)%')       { if ([int]$matches[1] -gt $cur.Signal) { $cur.Signal = [int]$matches[1] } }
            elseif ($line -match '^\s+Channel\s*:\s*(\d+)')       { $cur.Channels += [int]$matches[1] }
            elseif ($line -match '^\s+Radio type\s*:\s*(.+)$')    { $cur.Radio += $matches[1].Trim() }
        }
    }
    return ,$list
}

function Show-Networks($nets) {
    if (-not $nets -or $nets.Count -eq 0) { if (-not $script:LocationBlocked) { Finding 'No networks at all are visible.' }; return }
    $rows = $nets | Sort-Object Signal -Descending | ForEach-Object {
        [pscustomobject]@{
            SSID     = $_.SSID
            Signal   = "$($_.Signal)%"
            Channels = (($_.Channels | Sort-Object -Unique) -join ',')
            Radio    = (($_.Radio | Sort-Object -Unique) -join ',')
            Security = $_.Auth
        }
    }
    Show ($rows | Format-Table -AutoSize)
}

function Get-SavedProfiles {
    @(netsh wlan show profiles | Where-Object { $_ -match 'All User Profile\s*:\s*(.+)$' } |
      ForEach-Object { ($_ -split ':', 2)[1].Trim() })
}

function Find-Target {
    Invoke-WifiScan
    $n = Get-Networks
    Show-Networks $n
    $t = @($n | Where-Object { $_.SSID -match $MatchRx })
    if ($script:LocationBlocked) {
        Finding 'Windows blocked the Wi-Fi scan: turn on Settings > Privacy & security > Location (Location services + desktop apps), then run again.'
    }
    if ($n | Where-Object { $_.SSID -eq '<hidden>' }) {
        Info 'Note: a <hidden> network is listed. With an old Intel driver a Wi-Fi 6 router may appear this way.'
    }
    return @{ Nets = $n; Target = $t }
}

# ---- driver install: A) local folder ------------------------------------------
function Install-DriverFromFolder($a) {
    $devId = ([regex]::Match($a.PnPDeviceID, 'VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}')).Value
    if (-not $devId) { Info '(Could not read hardware ID)'; return $false }
    $drvDir = Join-Path $ScriptDir 'Driver'
    if (-not (Test-Path $drvDir)) { Info "No 'Driver' folder next to the script ($drvDir) - skipping local install."; return $false }

    $work = Join-Path $env:TEMP 'FixWiFi-Driver'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    Get-ChildItem -Path $drvDir -Recurse -File -Include *.cab -ErrorAction SilentlyContinue | ForEach-Object {
        $d = Join-Path $work $_.BaseName; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Info "Extracting $($_.Name)..."; & expand.exe -F:* "$($_.FullName)" "$d" | Out-Null
    }
    Get-ChildItem -Path $drvDir -Recurse -File -Include *.zip -ErrorAction SilentlyContinue | ForEach-Object {
        Info "Extracting $($_.Name)..."
        try { Expand-Archive -Path $_.FullName -DestinationPath (Join-Path $work $_.BaseName) -Force -ErrorAction Stop } catch { Info "  could not unzip: $($_.Exception.Message)" }
    }

    $cands = @()
    foreach ($inf in @(Get-ChildItem -Path $drvDir, $work -Recurse -File -Filter *.inf -ErrorAction SilentlyContinue)) {
        if (Select-String -Path $inf.FullName -Pattern $devId -SimpleMatch -Quiet) {
            $ver = $null
            $dv = Select-String -Path $inf.FullName -Pattern '^\s*DriverVer\s*=\s*[^,]+,\s*([\d\.]+)' | Select-Object -First 1
            if ($dv) { $ver = Get-Ver $dv.Matches[0].Groups[1].Value }
            $cands += [pscustomobject]@{ Inf = $inf.FullName; Version = $ver }
        }
    }
    if ($cands.Count -eq 0) {
        $exe = Get-ChildItem -Path $drvDir -Recurse -File -Filter *.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe -and (Ask "No .inf for this card found, but '$($exe.Name)' is in the Driver folder. Run that installer?")) {
            Start-Process -FilePath $exe.FullName -Wait
            return $true
        }
        Info "No driver in the Driver folder matches this card ($devId)."
        return $false
    }
    $best = $cands | Sort-Object Version -Descending | Select-Object -First 1
    $curV = Get-Ver $a.DriverVersion
    Info "Best local driver: $($best.Version)  ($($best.Inf))"
    if ($curV -and $best.Version -and $best.Version -le $curV) { Info "Not newer than installed $curV - skipping."; return $false }
    if (-not (Ask "Install driver $($best.Version) from the USB/Driver folder?")) { return $false }
    $out = & pnputil.exe /add-driver "$($best.Inf)" /install 2>&1
    Show $out
    if ($out -match 'reboot') { $script:NeedReboot = $true }
    return $true
}

# ---- driver install: B) Windows Update over the hotspot ------------------------
function Connect-ForInternet($a) {
    if (Test-Internet) { Ok 'Internet is available.'; return $true }
    $saved = Get-SavedProfiles
    for ($try = 0; $try -lt 3; $try++) {
        $scan  = Get-Networks
        $vis   = @($scan | Where-Object { $saved -contains $_.SSID -and $_.SSID -notmatch $MatchRx } | Sort-Object Signal -Descending)
        $pick  = $null
        if ($Hotspot) { $pick = $Hotspot }
        elseif ($vis.Count -gt 0) { $pick = $vis[0].SSID }
        if ($pick -and (Ask "Connect to '$pick' to download the driver from Windows Update? (uses a little mobile data, ~5 MB)")) {
            netsh wlan connect name="$pick" interface="$($a.Name)" | Out-Null
            for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Seconds 3; if (Test-Internet) { Ok "Online via '$pick'."; return $true } }
            Finding "Connected to '$pick' but no internet."
        }
        if ($Auto -or $NoFix) { break }
        $r = Read-Host '  >> Turn ON your phone hotspot (or any network used before on this laptop), then press Enter. Type S to skip'
        if ($r -match '^[Ss]') { break }
        Invoke-WifiScan
    }
    return $false
}

function Install-DriverFromWU($a) {
    $devId  = ([regex]::Match($a.PnPDeviceID, 'VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}')).Value
    $wuKey  = $WuPolicyKey
    $oldPol = (Get-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
    if ($oldPol -eq 1) { Set-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -Value 0 -Type DWord }
    $installed = $false
    try {
        $sess = New-Object -ComObject Microsoft.Update.Session
        $sess.ClientApplicationID = 'Fix-WiFi'
        $srch = $sess.CreateUpdateSearcher()
        $srch.ServerSelection = 2      # Windows Update (online)
        Info 'Searching Windows Update for drivers (1-5 minutes, please wait)...'
        $res = $srch.Search("IsInstalled=0 and Type='Driver'")
        $byId = @(); $byTitle = @()
        $curDate = $null; try { $curDate = [datetime]$a.DriverDate } catch {}
        foreach ($u in $res.Updates) {
            $hw = ''; try { $hw = [string]$u.DriverHardwareID } catch {}
            $ud = $null; try { $ud = [datetime]$u.DriverVerDate } catch {}
            if ($curDate -and $ud -and $ud.Date -le $curDate.Date) { continue }      # not newer than installed
            if ($devId -and $hw -match [regex]::Escape($devId)) { $byId += $u }
            elseif ($u.Title -match 'Wireless-?AC|Wireless-?N |Dual Band Wireless|Wi-?Fi 6') { $byTitle += $u }
        }
        $cands = if ($byId.Count -gt 0) { $byId } else { $byTitle }
        if ($cands.Count -eq 0) {
            Info "Windows Update found $($res.Updates.Count) driver(s), none newer for the Wi-Fi card:"
            foreach ($u in $res.Updates) { Info "   - $($u.Title)" }
            return $false
        }
        foreach ($u in $cands) { Info "Found: $($u.Title)" }
        if (-not (Ask 'Download and install this Wi-Fi driver now?')) { return $false }
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $cands) { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) }
        Info 'Downloading...'
        $dl = $sess.CreateUpdateDownloader(); $dl.Updates = $coll; [void]$dl.Download()
        Info 'Installing (Wi-Fi will drop for a moment)...'
        $ins = $sess.CreateUpdateInstaller(); $ins.Updates = $coll
        $r = $ins.Install()
        Info "Install result code: $($r.ResultCode)  (2 = succeeded, 3 = succeeded with errors)"
        if ($r.RebootRequired) { $script:NeedReboot = $true }
        $installed = ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3)
    } catch {
        Finding "Windows Update driver search failed: $($_.Exception.Message)"
    } finally {
        if ($oldPol -eq 1) { Set-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord }
    }
    return $installed
}

# ---- driver backup: export the installed (good) driver to the Driver folder ----
function Get-FolderDriverVersion([string]$dir, [string]$devId) {
    $best = $null
    foreach ($inf in @(Get-ChildItem -Path $dir -Recurse -File -Filter *.inf -ErrorAction SilentlyContinue)) {
        if (Select-String -Path $inf.FullName -Pattern $devId -SimpleMatch -Quiet) {
            $dv = Select-String -Path $inf.FullName -Pattern '^\s*DriverVer\s*=\s*[^,]+,\s*([\d\.]+)' | Select-Object -First 1
            if ($dv) { $v = Get-Ver $dv.Matches[0].Groups[1].Value; if ($v -and (-not $best -or $v -gt $best)) { $best = $v } }
        }
    }
    return $best
}

function Save-DriverToFolder($a) {
    if (-not $a -or (Test-DriverNeedsUpdate $a)) { return }
    Section 'DRIVER BACKUP (to the USB Driver folder)'
    $devId  = ([regex]::Match($a.PnPDeviceID, 'VEN_[0-9A-Fa-f]{4}&DEV_[0-9A-Fa-f]{4}')).Value
    $drvDir = Join-Path $ScriptDir 'Driver'
    $cur    = Get-Ver $a.DriverVersion
    $have   = Get-FolderDriverVersion $drvDir $devId
    if ($have -and $cur -and $have -ge $cur) { Ok "Driver $have is already saved in $drvDir"; return }

    $sd  = Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='NET'" -ErrorAction SilentlyContinue |
           Where-Object { $_.DeviceID -eq $a.PnPDeviceID } | Select-Object -First 1
    $oem = if ($sd) { $sd.InfName } else { $null }
    if (-not $oem) { Info '(Could not find the installed driver package - skipping backup)'; return }
    if (-not (Ask "Save a copy of the working driver $cur ($oem) to the USB Driver folder for next time?")) { return }

    $name = (($a.InterfaceDescription -replace '\s+#\d+$', '') -replace '\((R|TM)\)', '' -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $dest = Join-Path $drvDir "$name-$cur"
    try { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null }
    catch { Finding "Cannot write to $drvDir (USB read-only or removed?)"; return }

    $out = & pnputil.exe /export-driver $oem "$dest" 2>&1
    if (-not (Get-ChildItem -Path $dest -Recurse -File -Filter *.inf -ErrorAction SilentlyContinue)) {
        # Fallback for older pnputil: copy the package straight from the Windows driver store
        try {
            $src = (Get-WindowsDriver -Online -Driver $oem -ErrorAction Stop | Select-Object -First 1).OriginalFileName
            if ($src) { Copy-Item -Path (Join-Path (Split-Path $src -Parent) '*') -Destination $dest -Recurse -Force }
        } catch { Show $out }
    }
    if (Get-FolderDriverVersion $dest $devId) {
        Changed "Driver $cur saved to $dest"
        Info 'Next time the script installs it from here - no hotspot needed.'
    } else {
        Finding 'Driver backup failed - nothing usable was written.'
    }
}

# ================================================================ DIAGNOSTICS
Section '1. SYSTEM'
$csys = Get-CimInstance Win32_ComputerSystem
$os   = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS
Info "Computer   : $($csys.Manufacturer) $($csys.Model)"
Info "Windows    : $($os.Caption)  version $($os.Version)"
Info "BIOS       : $($bios.SMBIOSBIOSVersion)"
Info "Last boot  : $($os.LastBootUpTime)"
try { Info "Region     : $((Get-WinHomeLocation).HomeLocation)" } catch {}
if ($HaveTarget) { Info "Looking for: networks whose name contains '$Match'" } else { Info 'Looking for: (no network name given - general check)' }
Info "Script dir : $ScriptDir"
try {
    $ui = (Get-UICulture).Name
    if ($ui -notlike 'en*') { Finding "Windows display language is '$ui'. This script reads English 'netsh' output, so the network list and filter checks may be incomplete." }
} catch {}

Section '2. WI-FI ADAPTER'
$wifi = Find-WifiAdapter
if (-not $wifi) {
    Finding 'No Wi-Fi adapter found. Driver missing or Wi-Fi disabled in BIOS.'
    Show (Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Format-Table Status, FriendlyName, InstanceId -AutoSize)
} else {
    Show ($wifi | Format-List Name, InterfaceDescription, Status, MediaConnectionState, DriverProvider, DriverVersion, DriverDate, MacAddress, PnPDeviceID)
    if ($wifi.Status -eq 'Disabled') { Finding 'Wi-Fi adapter is DISABLED.' } else { Ok "Adapter '$($wifi.Name)' is enabled." }
    $dev = Get-PnpDevice -InstanceId $wifi.PnPDeviceID -ErrorAction SilentlyContinue
    if ($dev -and $dev.Status -ne 'OK') { Finding "Device Manager reports a problem: status $($dev.Status), problem code $($dev.Problem)" }
    if (Test-DriverNeedsUpdate $wifi) {
        Finding "Intel driver $($wifi.DriverVersion) is older than $GoodIntelLegacy. This bug HIDES Wi-Fi 6 routers (e.g. ISP-supplied AX routers). Driver update needed."
    } elseif (Test-LegacyIntel $wifi) {
        Ok "Driver $($wifi.DriverVersion) includes Intel's Wi-Fi 6 visibility fix."
    } elseif ((Test-IntelCard $wifi) -and $wifi.InterfaceDescription -match '\b(3165|3168|8260|8265)\b') {
        Info "Intel card: if your router is still missing, the newest Intel driver is the fix."
    }
}

Section '3. RADIO / AIRPLANE MODE'
try {
    $rs = (Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState' -ErrorAction Stop).GetValue('')
    if ($rs -eq 1) { Finding 'Airplane mode appears to be ON.' } else { Ok 'Airplane mode is off.' }
} catch { Info '(Airplane-mode state not readable)' }
$ifaces = netsh wlan show interfaces
Show ($ifaces)
if ($ifaces -match 'Software\s+Off') { Finding 'Wi-Fi radio is switched OFF in software (toggle Wi-Fi on in quick settings).' }
if ($ifaces -match 'Hardware\s+Off') { Finding 'Wi-Fi radio is switched OFF in hardware (Fn key / physical switch).' }

Section '4. SERVICES'
$svcs = Get-Service -Name 'WlanSvc', 'Dhcp', 'Dnscache', 'NlaSvc' -ErrorAction SilentlyContinue
Show ($svcs | Format-Table Name, DisplayName, Status, StartType -AutoSize)
$wlanSvc = $svcs | Where-Object Name -eq 'WlanSvc'
if ((-not $wlanSvc) -or $wlanSvc.Status -ne 'Running' -or $wlanSvc.StartType -ne 'Automatic') { Finding 'WLAN AutoConfig service is not running/automatic.' }
else { Ok 'WLAN AutoConfig is running.' }

Section '5. DRIVER CAPABILITIES'
$drv = netsh wlan show drivers
Show ($drv | Select-Object -First 14)
$radioLine = ($drv | Where-Object { $_ -match 'Radio types supported' }) -join ' '
if ($radioLine) { Info "=> $($radioLine.Trim())" }

Section '6. NETWORK FILTERS (blocked networks)'
$flt = netsh wlan show filters
$blocked = @(); $denyAll = $false; $sect = ''; $gp = $false
foreach ($l in $flt) {
    if     ($l -match '^Allow list') { $sect = 'allow'; $gp = ($l -match 'group policy') }
    elseif ($l -match '^Block list') { $sect = 'block'; $gp = ($l -match 'group policy') }
    elseif ($sect -eq 'block' -and $l -match 'SSID:\s*"(.*)"\s*,\s*Type:\s*(\S+)') {
        if ($matches[1] -eq '') { if (-not $gp) { $denyAll = $true } }
        else { $blocked += [pscustomobject]@{ SSID = $matches[1]; Type = $matches[2].ToLower(); GP = $gp } }
    }
    elseif ($sect -eq 'block' -and -not $gp -and $l -match 'Type:\s*\S+' -and $l -notmatch 'SSID') { $denyAll = $true }
}
$blockedTarget = @($blocked | Where-Object { $_.SSID -match $MatchRx })
if ($blockedTarget.Count -gt 0) { Finding "Network(s) BLOCKED by a Windows filter: $(($blockedTarget.SSID) -join ', ')" }
elseif ($blocked.Count -gt 0)  { Info "Other blocked networks: $(($blocked.SSID) -join ', ')" }
else                           { Ok 'No blocked networks.' }
if ($denyAll) { Finding "A 'block all networks' filter seems to be present." }

Section '7. SAVED WI-FI PROFILES'
$saved = Get-SavedProfiles
Info "Saved: $($saved -join ', ')"
$savedTarget = @($saved | Where-Object { $_ -match $MatchRx })
if ($savedTarget.Count -gt 0) { Info "Saved profile(s) for your network: $($savedTarget -join ', ')" }

Section '8. VISIBLE NETWORKS (fresh scan)'
$scan1  = Find-Target
$target = $scan1.Target
$allCh  = @($scan1.Nets | ForEach-Object { $_.Channels }) | Sort-Object -Unique
$ch24   = @($allCh | Where-Object { $_ -le 14 })
$ch5    = @($allCh | Where-Object { $_ -ge 32 })
if ($ch24.Count) { Info "2.4 GHz channels seen: $($ch24 -join ', ')" }
if ($ch5.Count)  { Info "5 GHz channels seen  : $($ch5 -join ', ')" } else { Info '5 GHz channels seen  : none' }
if ($target.Count -gt 0) { foreach ($t in $target) { Ok "'$($t.SSID)' IS visible (signal $($t.Signal)%, channel $(($t.Channels | Sort-Object -Unique) -join ','))" } }
elseif ($HaveTarget)     { Finding "Your network ('$Match') is NOT visible to this laptop." }

$pm = $null; $adv = @(); $regionProps = @(); $htProp = $null; $wmProp = $null
if ($wifi) {
    Section '9. ADAPTER ADVANCED SETTINGS'
    $adv = @(Get-NetAdapterAdvancedProperty -Name $wifi.Name -ErrorAction SilentlyContinue)
    Show ($adv | Sort-Object DisplayName | Format-Table DisplayName, DisplayValue -AutoSize)
    $htProp = $null; $wmProp = $null
    if (Test-IntelCard $wifi) {
        $htProp = $adv | Where-Object DisplayName -eq 'HT Mode' | Select-Object -First 1
        $wmProp = $adv | Where-Object DisplayName -eq 'Wireless Mode' | Select-Object -First 1
    }
    if ($htProp -and $htProp.DisplayValue -notmatch 'VHT') { Finding "HT Mode is '$($htProp.DisplayValue)' - 802.11ac is OFF (should be 'VHT Mode')." }
    elseif ($htProp) { Ok 'HT Mode = VHT Mode (802.11n + 802.11ac enabled).' }
    if ($wmProp -and $wmProp.DisplayValue -notmatch 'a/b/g') { Finding "Wireless Mode is '$($wmProp.DisplayValue)' - one band is switched off (should be '802.11a/b/g')." }
    elseif ($wmProp) { Ok "Wireless Mode = $($wmProp.DisplayValue) (correct; n/ac are controlled by HT Mode)." }
    $regionProps = @($adv | Where-Object { $_.DisplayName -match 'Country|Region' })

    Section '10. POWER MANAGEMENT'
    try {
        $pm = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop |
              Where-Object { $_.InstanceName.StartsWith($wifi.PnPDeviceID, [StringComparison]::OrdinalIgnoreCase) } |
              Select-Object -First 1
    } catch {}
    if ($pm -and $pm.Enable) { Finding "'Allow the computer to turn off this device to save power' is ON." }
    elseif ($pm)             { Ok 'Windows is not allowed to power off the Wi-Fi adapter.' }
}

Section '11. RECENT WLAN ERRORS (last 3 days)'
try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'; Level = 2, 3; StartTime = (Get-Date).AddDays(-3) } -MaxEvents 15 -ErrorAction Stop
    Show ($ev | Format-Table TimeCreated, Id, @{ n = 'Message'; e = { ($_.Message -split "`n")[0] } } -AutoSize -Wrap)
} catch { Ok 'No WLAN errors/warnings logged.' }

# ================================================================ REPAIRS
$target2 = $target
if ($NoFix) {
    Section 'REPAIRS SKIPPED (-NoFix)'
} else {
    Section 'REPAIRS  (press Enter = default answer)'

    foreach ($b in $blockedTarget) {
        if ($b.GP) { Finding "'$($b.SSID)' is blocked by GROUP POLICY - cannot remove here."; continue }
        if (Ask "Remove the Windows block on '$($b.SSID)'?") {
            netsh wlan delete filter permission=block ssid="$($b.SSID)" networktype=$($b.Type) | Out-Null
            Changed "Removed block filter for '$($b.SSID)'"
        }
    }
    if ($denyAll -and (Ask "Remove the 'block all networks' filter?")) {
        netsh wlan delete filter permission=denyall networktype=infrastructure | Out-Null
        Changed "Removed 'block all' filter"
    }
    if ((-not $wlanSvc) -or $wlanSvc.Status -ne 'Running' -or $wlanSvc.StartType -ne 'Automatic') {
        if (Ask 'Start the WLAN AutoConfig service (set to Automatic)?') {
            try { Set-Service WlanSvc -StartupType Automatic; Restart-Service WlanSvc -Force -ErrorAction Stop; Start-Sleep 4; Changed 'WLAN AutoConfig started' }
            catch { Finding "Could not start WlanSvc: $($_.Exception.Message)" }
        }
    }

    if ($wifi) {
        if ($wifi.Status -eq 'Disabled' -and (Ask 'Enable the Wi-Fi adapter?')) {
            Enable-NetAdapter -Name $wifi.Name -Confirm:$false; Start-Sleep -Seconds 5; Changed 'Wi-Fi adapter enabled'
        }
        if ($pm -and $pm.Enable -and (Ask 'Stop Windows from powering off the Wi-Fi adapter?')) {
            try { Set-CimInstance -InputObject $pm -Property @{ Enable = $false } -ErrorAction Stop; Changed 'Disabled power-saving turn-off for Wi-Fi' }
            catch { Finding "Could not change power setting: $($_.Exception.Message)" }
        }
        if ($htProp -and $htProp.DisplayValue -notmatch 'VHT') {
            $v = @($htProp.ValidDisplayValues) | Where-Object { $_ -match 'VHT' } | Select-Object -First 1
            if ($v -and (Ask "Set HT Mode to '$v' (turns on 802.11n/ac)?")) {
                Set-NetAdapterAdvancedProperty -Name $wifi.Name -DisplayName 'HT Mode' -DisplayValue $v; Start-Sleep 6; Changed "HT Mode -> $v"
            }
        }
        if ($wmProp -and $wmProp.DisplayValue -notmatch 'a/b/g') {
            $v = @($wmProp.ValidDisplayValues) | Where-Object { $_ -match 'a/b/g' } | Select-Object -Last 1
            if ($v -and (Ask "Set Wireless Mode to '$v'?")) {
                Set-NetAdapterAdvancedProperty -Name $wifi.Name -DisplayName 'Wireless Mode' -DisplayValue $v; Start-Sleep 6; Changed "Wireless Mode -> $v"
            }
        }
        foreach ($p in $regionProps) {
            $valid = @($p.ValidDisplayValues); $pick = $null
            if ($p.DisplayName -match '2\.4|2G|bg|B/G') {
                if ($p.DisplayValue -notmatch '13|14') { $pick = $valid | Where-Object { $_ -match '1\s*-\s*13' } | Select-Object -First 1 }
            } elseif ($p.DisplayName -match '5\s*G|5GHz') {
                if ($p.DisplayValue -notmatch '149') { $pick = $valid | Where-Object { $_ -match '36' -and $_ -match '149' } | Sort-Object Length -Descending | Select-Object -First 1 }
            }
            if ($pick -and (Ask "Change '$($p.DisplayName)' to '$pick'?")) {
                try { Set-NetAdapterAdvancedProperty -Name $wifi.Name -DisplayName $p.DisplayName -DisplayValue $pick -ErrorAction Stop; Changed "$($p.DisplayName) -> $pick"; Start-Sleep 6 }
                catch { Finding "Could not change $($p.DisplayName): $($_.Exception.Message)" }
            }
        }

        # -------------------------------------------------- DRIVER UPDATE (the main fix)
        $legacy     = Test-DriverNeedsUpdate $wifi
        $wantDriver = $legacy -or ($HaveTarget -and $target.Count -eq 0)
        if ($wantDriver) {
            Section 'DRIVER UPDATE'
            if ($legacy) { Info "Installed: $($wifi.DriverVersion)   Needed: $GoodIntelLegacy or newer" }
            else         { Info "Your network is missing - checking for a newer driver than $($wifi.DriverVersion)." }
            $done = Install-DriverFromFolder $wifi
            if ($done) { Start-Sleep -Seconds 5 }
            $wifi = Wait-WifiAdapter
            $stillNeed = (Test-DriverNeedsUpdate $wifi) -or (-not $legacy -and -not $done)
            if ($wifi -and $stillNeed -and (Ask 'Search Windows Update for a newer Wi-Fi driver (needs internet, e.g. a phone hotspot)?')) {
                if (Connect-ForInternet $wifi) {
                    $done = Install-DriverFromWU $wifi
                    Start-Sleep -Seconds 5
                    $wifi = Wait-WifiAdapter
                }
            }
            if ($legacy) {
                if ($wifi -and -not (Test-DriverNeedsUpdate $wifi)) { Changed "Wi-Fi driver is now $($wifi.DriverVersion)" }
                else { Finding "Driver is still $(if ($wifi) { $wifi.DriverVersion } else { 'unknown' }). See 'HOW TO GET THE DRIVER' in the summary." }
            } elseif ($done) {
                Changed "Wi-Fi driver updated, now $($wifi.DriverVersion)"
            }
        } else {
            if (Ask 'Disable and re-enable the Wi-Fi adapter (fresh start)?') { Restart-Wifi $wifi; Changed 'Wi-Fi adapter restarted' }
        }
    }

    Section 'RE-CHECK AFTER REPAIRS'
    $scan2   = Find-Target
    $target2 = $scan2.Target

    if ($target2.Count -eq 0) {
        if ($savedTarget.Count -gt 0 -and (Ask "Delete saved profile(s) '$($savedTarget -join ', ')' (you re-enter the password later)?" $false)) {
            foreach ($s in $savedTarget) { netsh wlan delete profile name="$s" | Out-Null }
            Changed 'Deleted saved profile(s) for your network'
        }
        if (Ask 'Reset Winsock and TCP/IP stack (needs a restart afterwards)?' $false) {
            netsh winsock reset | Out-Null; netsh int ip reset | Out-Null; ipconfig /flushdns | Out-Null
            Changed 'Winsock + TCP/IP reset'; $NeedReboot = $true
        }
    } else {
        foreach ($t in $target2) {
            if ($saved -contains $t.SSID) {
                if (Ask "Connect to '$($t.SSID)' now?") { netsh wlan connect name="$($t.SSID)" interface="$($wifi.Name)" | Out-Null; Start-Sleep 8 }
                break
            }
        }
    }

    # Keep a good driver from being replaced by Windows Update
    $wuKey = $WuPolicyKey
    $wuCur = (Get-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
    if ($wifi -and -not (Test-DriverNeedsUpdate $wifi) -and $wuCur -ne 1) {
        if (Ask 'Stop Windows Update from replacing drivers (keeps the good Wi-Fi driver; undo with -AllowDriverUpdates)?' (Test-LegacyIntel $wifi)) {
            if (-not (Test-Path $wuKey)) { New-Item -Path $wuKey -Force | Out-Null }   # never -Force an existing key: it would wipe other policies
            Set-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
            Changed 'Windows Update will no longer replace drivers'
        }
    }

    # Back up the working driver to the USB "Driver" folder for next time
    $wifi = Find-WifiAdapter
    Save-DriverToFolder $wifi
}

# ================================================================ SUMMARY
Section 'SUMMARY'
$wifi = Find-WifiAdapter
if ($wifi) { Info "Adapter: $($wifi.InterfaceDescription)  driver $($wifi.DriverVersion)" }
if ($Findings.Count) { Write-Host '  Problems found:' -ForegroundColor Yellow; $Findings | ForEach-Object { Write-Host "    - $_" } }
if ($Changes.Count)  { Write-Host '  Changes made:'   -ForegroundColor Green;  $Changes  | ForEach-Object { Write-Host "    - $_" } }

Write-Host ''
if (-not $HaveTarget) {
    Write-Host '  RESULT: general check done (no network name given). See the findings above.' -ForegroundColor Cyan
} elseif ($target2.Count -gt 0) {
    Write-Host "  RESULT: your network is VISIBLE: $(($target2.SSID) -join ', ')" -ForegroundColor Green
} else {
    Write-Host "  RESULT: your network ('$Match') is still NOT visible." -ForegroundColor Red
    if ($wifi -and (Test-DriverNeedsUpdate $wifi)) {
        Write-Host @'

  HOW TO GET THE DRIVER (Intel 18.33.17.1 for AC-3160), then run this script again:
   1. Easiest: turn on your phone hotspot and re-run - the script fetches it from Windows Update.
      (or: Settings > Update & Security > Windows Update > View optional updates > Driver updates)
   2. On another PC: catalog.update.microsoft.com -> search  18.33.17.1  -> download the .cab
      for "Intel - Net" (Windows 10, x64). Put the .cab in the "Driver" folder next to this
      script on the USB. The script extracts and installs it.
'@
    }
    Write-Host @'

  ROUTER-SIDE WORKAROUND (works even with the old driver):
   From a working device open http://192.168.1.1 (login on router sticker) -> Wi-Fi settings:
     * Wi-Fi mode / 802.11 mode : turn OFF 802.11ax (Wi-Fi 6), e.g. b/g/n and a/n/ac
     * 2.4 GHz channel : 1, 6 or 11      * 5 GHz channel : 36-48
     * Security : WPA2-PSK (AES) or WPA2/WPA3 mixed (not WPA3-only)
'@
}
if ($NeedReboot) { Write-Host '  >>> Please RESTART the laptop to finish. <<<' -ForegroundColor Magenta }

Write-Host ''
Write-Host "  Report: $report" -ForegroundColor Cyan
Stop-Transcript | Out-Null
try {
    Copy-Item -Path $report -Destination $ScriptDir -Force -ErrorAction Stop
    Write-Host "  Copy  : $(Join-Path $ScriptDir (Split-Path $report -Leaf))" -ForegroundColor Cyan
} catch {}
Read-Host '  Finished - press Enter'
