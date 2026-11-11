# Fix-WiFi

A one-click Windows 10/11 Wi-Fi diagnostic and repair script. It was built for the **Dell Inspiron 5559** and its Intel Dual Band Wireless-AC 3160 / 3165 cards, and most of the checks work on any Windows laptop.

It targets this problem in particular:

> *My home Wi-Fi doesn't show up in the list. Other networks do, and my other devices connect fine.*

On the Inspiron 5559 this is almost always caused by the **old Intel AC-3160 driver (older than 18.33.17.1)**, which can't see **Wi-Fi 6 (802.11ax) routers**. Many ISPs now supply Wi-Fi 6 routers. Windows Update sometimes puts the old driver back, so the problem can return without warning.

## What it does

It **diagnoses first, without changing anything**, and saves a report:

- Wi-Fi adapter, driver version and age, Device Manager status
- Airplane mode, hardware/software radio switch
- WLAN AutoConfig and related services
- Windows network block filters (`netsh wlan show filters`)
- Saved profiles, and a fresh scan with channels, radio types and security
- Adapter advanced settings (HT Mode, Wireless Mode, region), power management
- Recent WLAN errors from the event log

Then it **offers fixes one at a time (Y/N)**:

- Removes Windows block filters on your network
- Restarts or enables the Wi-Fi service and adapter
- Stops Windows from powering off the adapter
- Fixes HT Mode / Wireless Mode / region settings if they're wrong
- **Installs a newer Wi-Fi driver**, either
  - from the `Driver\` folder next to the script (`.cab`, `.zip` or extracted `.inf`), or
  - from **Windows Update**, connecting to a phone hotspot first if the laptop has no internet
- **Backs up the working driver** into `Driver\`, so the next fix works offline
- Optionally stops Windows Update from replacing drivers again (undo with `-AllowDriverUpdates`)
- Optionally resets Winsock/TCP-IP (off by default)

If your network still doesn't show up, it prints the **router-side workaround**: turn off 802.11ax, and use channels 1/6/11 and 36–48 with WPA2.

## Usage

1. Download or clone this repo onto a USB stick, keeping the folder together:
   ```
   Fix-WiFi\
     Run-Fix-WiFi.cmd
     Fix-WiFi.ps1
     Driver\
   ```
2. On the affected laptop, **double-click `Run-Fix-WiFi.cmd`**. It works around the
   *"running scripts is disabled on this system"* error and asks for admin rights.
3. Type part of the name of the missing network when asked, then press **Enter** to accept
   each default answer.

Command-line options:

```powershell
powershell -ExecutionPolicy Bypass -File .\Fix-WiFi.ps1 -Match "MyHomeWiFi"
```

| Option | Meaning |
|---|---|
| `-Match "name"` | Part of the missing network's name (asked if omitted) |
| `-Hotspot "name"` | Saved hotspot/network to use for downloading a driver |
| `-NoFix` | Diagnose only, change nothing |
| `-Auto` | Accept every default answer without asking |
| `-AllowDriverUpdates` | Undo the "block driver updates" setting and exit |

## Getting the AC-3160 driver (18.33.17.1)

Intel no longer offers downloads for the AC-3160, 7260 and 7265 (Rev C) cards. Ways to get the driver:

1. **Let the script do it.** Turn on a phone hotspot that the laptop has used before, then run the script. It finds the driver on Windows Update.
2. **Microsoft Update Catalog.** On another PC, search [catalog.update.microsoft.com](https://www.catalog.update.microsoft.com) for `18.33.17.1`, download the Windows 10 x64 *Intel – Net* `.cab`, and drop it into `Driver\`.
3. After one successful fix, the script saves a copy into `Driver\` for you.

## Limitations

- **English Windows only for some checks.** The script reads the text output of `netsh`, so on other display languages the network list and filter checks may be incomplete. It warns you when that applies.
- **Windows 11 24H2 and later** need Location services turned on before any app can scan for Wi-Fi networks. The script tells you if the scan was blocked.
- The driver version check is specific to the Intel AC-3160, 7260 and 7265. For other cards the script only offers whatever newer driver Windows Update has.

## Reports and privacy

Each run saves `WiFi-Report-<date>.txt` to the Desktop **and** next to the script. Reports contain network names, MAC addresses and your Windows user name. **Redact them before attaching one to a public issue.**

## Tested on

- Dell Inspiron 5559, Intel Dual Band Wireless-AC 3160, Windows 10 Home 22H2 (19045)

Reports from other models and cards are welcome via issues or PRs.

## Disclaimer

Not affiliated with Dell, Intel or Microsoft. The script changes system network settings and drivers, and only after asking (unless you use `-Auto`). Use at your own risk. See [LICENSE](LICENSE).
