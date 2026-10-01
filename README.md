# MediaPC-Toolkit

Windows prep scripts for media / show PCs.

## `profiles/Prepare-PlayoutPC.ps1` - uninterrupted playout on a fresh Windows 10/11 install

Prepares a fresh install for 24/7 playout (digital signage, exhibitions, media servers, vvvv, any player software).
Third-party apps run normally (UAC is untouched, the firewall stays on). Anything from Windows that could interrupt the
show is switched off: updates and reboots, update/remediation tasks, automatic maintenance, Defender scans,
notifications, lock screen, SmartScreen / security-warning prompts, crash dialogs, "restart apps" behaviour and more.

The requirements the script is reviewed against are in [`docs/SPEC.md`](docs/SPEC.md).

### Profiles

| Profile | Entry point | What it adds |
|---|---|---|
| `Generic` (default) | `profiles/Prepare-PlayoutPC.ps1` | the hardening only |
| `vvvv` | `profiles/Prepare-PlayoutPC_vvvv.ps1` (wrapper, same as `-PlayoutProfile vvvv`) | prerequisite step for exported vvvv gamma apps, run **before** the update lock |

`Prepare-PlayoutPC_vvvv.ps1` only forwards to `Prepare-PlayoutPC.ps1`: keep both files in the same folder.

Exports that reference VL.Stride need the Visual C++ Redistributable and .NET on the target PC (see the gray book
*Exporting Applications* page for the exact versions of your vvvv release). Because Windows Update, Store and
feature-on-demand installs are blocked afterwards, the vvvv profile checks the VC++ 2015-2022 x64 Redistributable
(`-VcRedistMinVersion`) and the .NET SDK/runtime (`-DotNetMajor 8 -DotNetKind SDK|DesktopRuntime|Runtime`), installs what
is missing via `winget` (`-InstallPrerequisites`, or menu 15) and **refuses to lock Windows Update while they are missing**
(unattended runs exit with code 1; override with `-LockWithoutPrerequisites`).

### Recommended order on a fresh machine

1. Install Windows, run **one final patch cycle**, reboot until nothing is pending.
2. Install GPU / chipset / NIC drivers. vvvv profile: then the prerequisites (menu 15 or `-InstallPrerequisites`).
3. Run the script (start with `-WhatIf`), reboot.
4. Install your player software and content, test, image the machine.
5. For deliberate maintenance later: menu **14** (unlock updates) -> patch -> reboot -> menu **3** (lock again).

### Run it

Elevated *Windows PowerShell 5.1* (`powershell.exe`, not `pwsh`). Files downloaded from GitHub carry Mark-of-the-Web:

```powershell
Get-ChildItem .\profiles\*.ps1 | Unblock-File
powershell.exe -ExecutionPolicy Bypass -File .\profiles\Prepare-PlayoutPC.ps1 -WhatIf `
    -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout

# vvvv, fully unattended (imaging / deployment); exit code 1 if any action failed
powershell.exe -ExecutionPolicy Bypass -File .\profiles\Prepare-PlayoutPC_vvvv.ps1 -Unattended -InstallPrerequisites `
    -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout -MediaPaths D:\Media -DailyRebootTime 04:30
```

### Windows Update

Blocked by default: policies, update services (`wuauserv`, `UsoSvc`, `WaaSMedicSvc`, `DoSvc`, `sedsvc`), the
UpdateOrchestrator / WindowsUpdate / WaaSMedic / InstallService tasks, upgrade offers, driver updates and automatic
reboots. Windows' own remediation can re-enable parts of this, so a hidden SYSTEM task `Playout-UpdateGuard` (at startup
and every 30 minutes) re-applies the block. Its script and state live in `%ProgramData%\PlayoutPrep`, which is restricted
to SYSTEM and Administrators. The lock is verified afterwards (`wuauserv`, `UsoSvc` and the policy must be in place,
otherwise an ERROR is logged). `-AllowUpdates` keeps updates notify-only instead (no guard task).

Menu 14 opens a maintenance window and re-enables only the tasks this script disabled (recorded in
`disabled-tasks.json`). Side effects while blocked: Store installs, `winget` msstore sources and feature-on-demand
installs (e.g. .NET Framework 3.5) fail, and Defender definitions stop updating.

### Parameters

| Parameter | Purpose |
|---|---|
| `-PlayoutProfile Generic/vvvv` | Profile (see above) |
| `-Unattended`, `-IncludeDebloat` | No prompts; debloat only with `-IncludeDebloat`; auto-logon only if user + password are passed |
| `-InstallPrerequisites`, `-LockWithoutPrerequisites`, `-DotNetMajor`, `-DotNetKind`, `-VcRedistMinVersion` | vvvv profile prerequisites |
| `-AllowUpdates` | Notify-only updates instead of blocking |
| `-AppPath`, `-AppArguments` | Player executable: enables watchdog task, firewall rule, Defender process exclusion, per-app GPU flags, crash dumps |
| `-KioskUser` | Account that runs the app; per-user (HKCU) tweaks and the watchdog target this user instead of the elevated admin |
| `-MediaPaths` | Folders excluded from Defender real-time scanning |
| `-FirewallProfiles` | Profiles for the app's inbound allow rule (default `Private,Domain,Public`: new networks default to Public because the discovery prompt is suppressed) |
| `-SetNetworkPrivate`, `-NtpServers` | Network profile and NTP peers |
| `-TargetRelease` | Pin the feature release (`24H2`, `22H2`, ...) |
| `-HAGS On/Off/Leave`, `-DisableMPO` | Optional GPU scheduling / overlay workarounds; decide empirically |
| `-DailyRebootTime HH:mm` | Daily maintenance reboot task |
| `-Aggressive` | Also disables the search indexer, memory compression, Memory Integrity/VBS. Dedicated, isolated machines only |
| `-RunElevated` | Watchdog runs with highest privileges (only elevates for administrator accounts) |
| `-AutoLogon*` | Auto-logon (default method: Sysinternals Autologon; the result is read back and verified) |

Menu option 13 shows the current state (power plan, update lock, tasks, services, auto-logon, prerequisites).

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
Auto-logon is not part of "Run all" because it stores a credential; the `Registry` method stores the password in plaintext.

### Tests

```powershell
powershell.exe -File .\tests\Invoke-Tests.ps1     # Pester 5 + PSScriptAnalyzer (also runs on pwsh / Linux)
```

The tests extract functions from the script and check them with mocks (prerequisite detection, native-command error
handling) and guard the fixes from code review (update-lock gate, guard-folder ACL, auto-logon verification, ...).
**The script has not yet been run on a Windows machine**: follow the test plan in [`docs/SPEC.md`](docs/SPEC.md) on a
non-production box first.
