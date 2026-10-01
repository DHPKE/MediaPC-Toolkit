# MediaPC-Toolkit

Windows prep scripts for media / show PCs.

## `profiles/Prepare-PlayoutPC.ps1` - uninterrupted playout on a fresh Windows 10/11 install

Prepares a fresh install for 24/7 playout (digital signage, exhibitions, media servers, vvvv, any player software).
Third-party apps run normally (UAC is untouched). Anything from Windows that could interrupt the show is switched off:
updates and reboots, update/remediation tasks, automatic maintenance, Defender scans, notifications, lock screen,
SmartScreen / security-warning prompts, crash dialogs, vendor "restart apps" behaviour and more.

### Recommended order on a fresh machine

1. Install Windows, run **one final patch cycle**, reboot until nothing is pending.
2. Install GPU / chipset / NIC drivers.
3. Run the script (start with `-WhatIf`), reboot.
4. Install your player software and content, test, image the machine.
5. For deliberate maintenance later: menu **14** (unlock updates) -> patch -> reboot -> menu **3** (lock again).

### Run it

Elevated *Windows PowerShell 5.1* (`powershell.exe`, not `pwsh`). Files downloaded from GitHub carry Mark-of-the-Web:

```powershell
Unblock-File .\profiles\Prepare-PlayoutPC.ps1
powershell.exe -ExecutionPolicy Bypass -File .\profiles\Prepare-PlayoutPC.ps1 -WhatIf `
    -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout

# fully unattended (imaging / deployment); exit code 1 if any action failed
powershell.exe -ExecutionPolicy Bypass -File .\profiles\Prepare-PlayoutPC.ps1 -Unattended `
    -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout -MediaPaths D:\Media -DailyRebootTime 04:30
```

### Windows Update

Blocked by default: policies, update services (`wuauserv`, `UsoSvc`, `WaaSMedicSvc`, `DoSvc`, `sedsvc`), the
UpdateOrchestrator / WindowsUpdate / WaaSMedic tasks, upgrade offers, driver updates and automatic reboots. Windows'
own remediation can re-enable parts of this, so a hidden SYSTEM task `Playout-UpdateGuard` (at startup and every
30 minutes) re-applies the block. `-AllowUpdates` keeps updates notify-only instead (no guard task).

Side effects while blocked: Store installs, `winget` msstore sources and feature-on-demand installs (e.g. .NET
Framework 3.5) fail, and Defender definitions stop updating. Use menu 14 for a maintenance window.

### Parameters

| Parameter | Purpose |
|---|---|
| `-Unattended`, `-IncludeDebloat` | No prompts; debloat only with `-IncludeDebloat`; auto-logon only if user + password are passed |
| `-AllowUpdates` | Notify-only updates instead of blocking |
| `-AppPath`, `-AppArguments` | Player executable: enables watchdog task, firewall rule, Defender process exclusion, per-app GPU flags, crash dumps |
| `-KioskUser` | Account that runs the app; per-user (HKCU) tweaks and the watchdog target this user instead of the elevated admin |
| `-MediaPaths` | Folders excluded from Defender real-time scanning |
| `-TargetRelease` | Pin the feature release (`24H2`, `22H2`, ...) |
| `-HAGS On/Off/Leave`, `-DisableMPO` | Optional GPU scheduling / overlay workarounds; decide empirically |
| `-DailyRebootTime HH:mm` | Daily maintenance reboot task |
| `-SetNetworkPrivate`, `-NtpServers` | Network profile and NTP peers |
| `-Aggressive` | Also disables the search indexer, memory compression, Memory Integrity/VBS. Dedicated, isolated machines only |
| `-RunElevated` | Watchdog runs with highest privileges (only elevates for administrator accounts) |

Menu option 13 shows the current state (power plan, update lock, tasks, services) so changes can be verified.

### Notes

- Use **Pro, Enterprise or IoT Enterprise LTSC**. Windows Home ignores many of the policies used here.
- Windows 10 no longer receives security updates without ESU. For new installs prefer Windows 11 or LTSC, and keep
  playout machines on an isolated network while updates are blocked.
- Smart App Control (Windows 11 fresh installs) and Defender Tamper Protection must be switched off by hand if needed.

### Rollback: what is and is not covered

Before the first change the script creates a System Restore point and `.reg` exports of the keys it touches
(`C:\Playout-Prep-Backup-<timestamp>\`). These do **not** cover: service start types, scheduled tasks, the power plan,
NIC properties, firewall rules, Defender preferences, w32time configuration, AppX packages, or the kiosk user's profile
hive. AppX removal is irreversible without reinstalling the apps and also removes those apps' own data.
Auto-logon is not part of "Run all" because it stores a credential; the default method is Sysinternals Autologon
(encrypted LSA secret), the `Registry` method stores the password in plaintext.

The script is parse-checked but **not yet validated on a Windows machine**. Test on a non-production box first.
