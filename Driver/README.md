# Driver folder

Put a Wi-Fi driver here and `Fix-WiFi.ps1` will extract and install it:

- a `.cab` from the Microsoft Update Catalog (for the Intel AC-3160, search `18.33.17.1`)
- a `.zip` of the driver
- an already extracted folder with `.inf` files

After a successful fix the script also **saves a copy of the working driver here**
(for example `Intel-Dual-Band-Wireless-AC-3160-18.33.17.1\`), so the next fix needs no internet.

Driver files are excluded by `.gitignore`. Don't commit or redistribute vendor drivers.
