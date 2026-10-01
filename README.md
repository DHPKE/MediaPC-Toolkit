# MediaPC-Toolkit

Windows prep scripts for media / show PCs.

## Profiles

### `profiles/Playout-vvvv-NVIDIA-Win11.ps1`

Interactive Windows 11 prep for 24/7 media playout with vvvv (gamma) on NVIDIA RTX A2000 / T1000.

**Run it** in an elevated *Windows PowerShell 5.1* (`powershell.exe`, not `pwsh`). Files downloaded from GitHub carry
Mark-of-the-Web, so unblock first:

```powershell
Unblock-File .\profiles\Playout-vvvv-NVIDIA-Win11.ps1
powershell.exe -ExecutionPolicy Bypass -File .\profiles\Playout-vvvv-NVIDIA-Win11.ps1 -WhatIf `
    -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout
```

Always start with `-WhatIf`; nothing changes and everything is logged.

| Parameter | Purpose |
|---|---|
| `-AppPath` | vvvv export (or `vvvv.exe`): enables watchdog task, firewall rule, Defender process exclusion, per-app GPU flags, crash dumps |
| `-AppArguments` | Arguments for the watchdog launch |
| `-KioskUser` | Account that runs the app; per-user (HKCU) tweaks and the watchdog target this user instead of the elevated admin |
| `-MediaPaths` | Folders excluded from Defender real-time scanning |
| `-TargetRelease` | Pin the Windows 11 feature release (e.g. `24H2`) |
| `-HAGS On/Off/Leave`, `-DisableMPO` | Optional GPU scheduling / overlay workarounds; decide empirically |
| `-DailyRebootTime HH:mm` | Daily maintenance reboot task |
| `-SetNetworkPrivate` | Switch connected Public networks to Private |
| `-Aggressive` | Disables update services, search indexer, Defender scheduled scan, memory compression, Memory Integrity/VBS. Dedicated, isolated machines only |
| `-RunElevated` | Watchdog runs with highest privileges (only elevates for administrator accounts) |

Menu option 13 shows the current state (power plan, tasks, services, policies) so changes can be verified.

### Rollback: what is and is not covered

Before the first change the script creates a System Restore point and `.reg` exports of the keys it touches
(`C:\Playout-Prep-Backup-<timestamp>\`). These do **not** cover: service start types, scheduled tasks, the power plan,
NIC properties, firewall rules, Defender preferences, w32time configuration, AppX packages, or the kiosk user's profile
hive. AppX removal (section 8) is irreversible without reinstalling the apps and also removes those apps' own data.
Auto-logon (section 10) is not part of "Run all" because it stores a credential; the default method is Sysinternals
Autologon (encrypted LSA secret), the `Registry` method stores the password in plaintext.

The script has been parse-checked but has not yet been validated on a Windows 11 machine. Test on a non-production box first.
