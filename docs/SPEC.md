# Specification: uninterrupted playout prep (Prepare-PlayoutPC.ps1)

Acceptance criteria the script is reviewed and tested against. "Auto" = covered by `tests/` (runs without Windows),
"Menu 13" = visible with *Verify current state*, "Manual" = needs a Windows test machine (see the test plan below).

| ID | Requirement | Implemented in | Verified by |
|---|---|---|---|
| AC1 | A fresh Windows 10/11 install runs a playout app 24/7 without Windows interrupting it (updates, reboots, scans, maintenance, popups, lock screen, prompts). Third-party apps run normally. | `Invoke-Updates`, `Invoke-Background`, `Invoke-Distractions`, `Invoke-Power` | Manual soak test (AC12) |
| AC2 | UAC is not touched and the firewall is not disabled. | whole script | Auto (`Documented invariants`) |
| AC3 | Windows Update is blocked: policies, update services, update/orchestrator/remediation tasks, upgrade offers, driver updates, auto-reboot. The block is re-applied if Windows re-enables parts of it. | `Invoke-Updates`, `Install-UpdateGuard` | Auto (guards), Menu 13, `Test-UpdateLock` (ERROR if `wuauserv`/`UsoSvc`/policy not applied) |
| AC4 | The update guard runs SYSTEM code only from a folder writable by SYSTEM and Administrators. | `Initialize-StateDir`, `Install-UpdateGuard` | Auto (`icacls` + SIDs present), Manual (`icacls %ProgramData%\PlayoutPrep`) |
| AC5 | vvvv profile: VC++ Redistributable (>= `-VcRedistMinVersion`) and .NET (`-DotNetMajor`/`-DotNetKind`) are present before Windows Update is locked; the lock is refused otherwise (exit code 1 unattended) unless `-LockWithoutPrerequisites`. | `Test-PrerequisitesMet`, `Invoke-Prerequisites`, `Invoke-Updates` | Auto (`Test-DotNetPresent`, `Test-VcRedist`, `Test-PrerequisitesMet`, gate guard), Menu 13 |
| AC6 | Maintenance is possible on purpose: menu 14 unlocks updates and re-enables only the tasks this script disabled; menu 3 locks again. | `Invoke-UpdateUnlock`, `Add-DisabledTaskList` | Auto (guard), Manual |
| AC7 | Every action's result is reported truthfully: non-terminating errors and native exit codes count as failures; unattended runs exit 1 if any ERROR was logged. Windows-protected items are WARNs. | `Invoke-Action`, `Invoke-Native`, `Write-PlayoutLog` | Auto (`Invoke-Native`), review |
| AC8 | The playout app is restarted within ~1 minute if it exits or crashes; crash dialogs do not keep the process alive; crash dumps are kept. | `Invoke-Watchdog`, `Invoke-Resilience` | Manual (kill the process) |
| AC9 | Inbound traffic to the app is allowed on the profiles chosen with `-FirewallProfiles` (default: all, because new networks default to Public). | `Invoke-Network` | Auto (default), Manual (`Get-NetFirewallRule`) |
| AC10 | Auto-logon is verified by reading the Winlogon values back; the password is never written to the log or an exception message. | `Invoke-AutoLogon`, `Test-AutoLogonConfigured` | Auto (guard), Manual (reboot) |
| AC11 | Rollback limits are documented (what the restore point and `.reg` exports do and do not cover). | `README.md`, `New-SafetyBackup` | Review |
| AC12 | Validation status is stated honestly. | `README.md` | Review |

## Test plan on Windows (not yet executed)

1. Fresh Windows 11 Pro VM and a Windows 10 22H2 VM. Run `-WhatIf`, then a real run, reboot.
2. Menu 13: power plan "24-7 Playout" active, `NoAutoUpdate=1`, `wuauserv`/`UsoSvc` Disabled, guard task present.
3. Re-enable `wuauserv` by hand, wait for the guard (or run it): confirm it is disabled again.
4. `icacls %ProgramData%\PlayoutPrep` shows only SYSTEM and Administrators.
5. vvvv profile on a machine without the VC++ Redistributable: lock is refused and the unattended run exits 1; with
   `-InstallPrerequisites` the prerequisites install and the lock succeeds.
6. Menu 14 then menu 3: only update tasks recorded in `disabled-tasks.json` are re-enabled and then disabled again.
7. Kill the app: it returns within ~1 minute. Reboot with auto-logon: the kiosk user logs on and the app starts.
8. A UDP listener on a new (Public) network receives inbound traffic with default `-FirewallProfiles`.
9. 24-48 h soak: no updates, reboots, popups or focus loss.
