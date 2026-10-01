#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prepare a FRESH Windows 10 / 11 install for 24/7, uninterrupted playout with vvvv gamma
    (exported applications; digital signage, exhibitions, media servers).

    vvvv variant of Prepare-PlayoutPC.ps1: identical hardening, plus a prerequisite step that makes
    sure the Visual C++ Redistributable and the .NET SDK/runtime that exported vvvv apps need are
    installed BEFORE Windows Update, Store and feature-on-demand installs are blocked.

.DESCRIPTION
    Principle: Windows must never update, reboot, scan, prompt, pop up or take focus while the
    show runs. Third-party applications keep running normally (UAC is not touched).

    Recommended order on a fresh machine
      1. Install Windows, run ONE final patch cycle, reboot until nothing is pending.
      2. Install GPU / chipset / NIC drivers, then the vvvv prerequisites (VC++ Redistributable +
         .NET; -InstallPrerequisites or menu 15) so they are in place BEFORE updates are blocked.
      3. Run this script (start with -WhatIf), reboot.
      4. Install your player software and content; test; image the machine.
      5. For deliberate maintenance later use menu 14 (unlock updates), then menu 3 to lock again.

    Menu-driven or fully unattended (-Unattended). Reversible where possible:
      * -WhatIf dry run (nothing is changed except the log file)
      * System Restore point + .reg exports of touched keys before the first change
      * Every action is logged; failures are logged as failures (exit code 1 when unattended)
      * Does NOT touch UAC, does NOT disable the firewall, does NOT delete user files
        (AppX removal in section 8 does remove those apps' own data)

    Sections
      2  Power: dedicated "24-7 Playout" plan, no sleep/hibernate/Fast Startup, no core parking,
         PCIe ASPM + USB selective suspend off, power throttling off, timer resolution (Win11)
      3  Windows Update: BLOCKED (policies, services, update/remediation tasks, upgrade offers,
         no auto-reboot, no driver updates) plus a SYSTEM "update guard" task that re-applies
         the block if Windows' remediation re-enables anything. -AllowUpdates = notify-only instead
      4  Graphics: Game DVR off, swap-chain upgrade off, per-app GPU + fullscreen-opt flags,
         optional HAGS / MPO control
      5  Distractions: hotkeys, toasts, lock screen, screensaver, AutoPlay, ads, SmartScreen /
         Mark-of-the-Web prompts, network-discovery prompt, restart-app restore
      6  Background: telemetry/maintenance tasks and services, automatic maintenance off, Edge
         updater/background mode off, Defender scans off (real-time protection stays on) and
         exclusions for media paths
      7  Network/time: NIC power saving off, firewall rule for the app, NTP
      8  Debloat: conservative AppX removal, OneDrive, telemetry policy
      9  Resilience: crash dialogs off + crash dumps, no auto-restart sign-in, BSOD auto-reboot,
         watchdog task, optional daily reboot
      10 Auto-logon (kept OUT of "Run all" because it stores a credential)
      11 Post-install checklist, 13 Verify current state, 14 Unlock updates (maintenance window),
      15 vvvv prerequisites: VC++ Redistributable + .NET check/install (runs BEFORE the update lock)

    -Aggressive additionally: disables the search indexer, memory compression and Memory
    Integrity/VBS. Use on dedicated, isolated playout machines only.

.PARAMETER Unattended
    No prompts: back up, run all sections, verify, exit. Debloat only with -IncludeDebloat;
    auto-logon only if -AutoLogonUserName and -AutoLogonPassword are supplied.

.PARAMETER IncludeDebloat
    Include section 8 in "Run all" / -Unattended (AppX removal is not covered by the restore point).

.PARAMETER InstallPrerequisites
    Install missing vvvv prerequisites via winget without asking (needs internet and winget /
    App Installer for the account running the script).

.PARAMETER DotNetMajor / DotNetKind
    .NET major version (default 8) and kind (SDK default, DesktopRuntime, Runtime) to check/install.
    Check the gray book 'Exporting Applications' page for what YOUR vvvv version requires on the
    target PC (apps that reference VL.Stride need the VC++ Redistributable and .NET on the target).

.PARAMETER AllowUpdates
    Keep Windows Update in notify-only mode instead of blocking it (no guard task).

.PARAMETER AppPath
    Full path to the player (.exe). Enables the watchdog task, firewall rule, Defender process
    exclusion, per-app GPU settings and crash dumps.

.PARAMETER AppArguments
    Command-line arguments passed to the app by the watchdog task.

.PARAMETER KioskUser
    Account that runs the player (e.g. "playout"). Per-user (HKCU) settings and the watchdog task
    are applied to THIS account instead of whoever is running the script.

.PARAMETER RunElevated
    Watchdog task runs the app with highest privileges (only elevates for administrator accounts).

.PARAMETER MediaPaths
    Folders excluded from Defender real-time scanning (media libraries, cache).

.PARAMETER TargetRelease
    Pin the feature release, e.g. '24H2' (Win11) or '22H2' (Win10). Empty = don't pin.

.PARAMETER HAGS
    Hardware-accelerated GPU scheduling: Leave (default), On, Off. Reboot required.

.PARAMETER DisableMPO
    Disable Multiplane Overlay in DWM. Only use if you see flicker/tearing/black frames.

.PARAMETER SetNetworkPrivate
    Switch connected 'Public' networks to 'Private' (so Private firewall rules/discovery apply).

.PARAMETER DailyRebootTime
    'HH:mm' - creates a daily maintenance reboot task (SYSTEM).

.PARAMETER AppsToKeep
    Extra AppX package names that debloat must not remove.

.PARAMETER AutoLogonUserName / AutoLogonDomain / AutoLogonPassword / AutoLogonMethod / AutologonExePath
    Section 10. Default method is 'Sysinternals' (Microsoft's Autologon tool, encrypted LSA secret;
    supply the path to a copy you downloaded yourself). 'Registry' stores the password in PLAINTEXT
    under Winlogon. The password is passed on a command line for a moment: use a trusted console.

.EXAMPLE
    .\Prepare-PlayoutPC_vvvv.ps1 -WhatIf -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout

.EXAMPLE
    .\Prepare-PlayoutPC_vvvv.ps1 -Unattended -AppPath "C:\Playout\Show\Show.exe" -KioskUser playout `
        -MediaPaths D:\Media -DailyRebootTime 04:30 -NtpServers pool.ntp.org -InstallPrerequisites
#>
param(
    [switch]$WhatIf,
    [switch]$Unattended,
    [switch]$IncludeDebloat,
    [switch]$AllowUpdates,
    [switch]$InstallPrerequisites,
    [ValidatePattern('^\d+$')][string]$DotNetMajor = '8',
    [ValidateSet('SDK','DesktopRuntime','Runtime')][string]$DotNetKind = 'SDK',
    [switch]$Aggressive,
    [string]$AppPath,
    [string]$AppArguments,
    [string]$KioskUser,
    [switch]$RunElevated,
    [string[]]$MediaPaths = @(),
    [string]$TargetRelease,
    [ValidateSet('Leave','On','Off')][string]$HAGS = 'Leave',
    [switch]$DisableMPO,
    [switch]$SetNetworkPrivate,
    [string[]]$NtpServers = @('time.windows.com'),
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')][string]$DailyRebootTime,
    [string[]]$AppsToKeep = @(),
    [string]$AutoLogonUserName,
    [string]$AutoLogonDomain,
    [System.Security.SecureString]$AutoLogonPassword,
    [ValidateSet('Registry','Sysinternals')][string]$AutoLogonMethod = 'Sysinternals',
    [string]$AutologonExePath
)

if ($PSVersionTable.PSVersion.Major -gt 5) {
    Write-Warning "Run this in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7: AppX, restore-point and several other cmdlets need it."
    exit 1
}

$ErrorActionPreference = 'Continue'
$script:Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:LogFile    = Join-Path $env:SystemDrive "Playout-Prep-$($script:Stamp).log"
$script:BackupDone = $false
$script:UserRoot   = 'HKCU:'
$script:UserRegKey = 'HKCU'
$script:HiveLoaded = $false
$script:ErrorCount = 0

$script:OsInfo  = Get-CimInstance Win32_OperatingSystem
$script:Build   = [int]$script:OsInfo.BuildNumber
$script:IsWin11 = ($script:Build -ge 22000)
$script:OsLabel = "$($script:OsInfo.Caption) (build $($script:Build))"

$script:UpdateTaskPaths = @(
    '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\WindowsUpdate\',
    '\Microsoft\Windows\WaaSMedic\',
    '\Microsoft\Windows\InstallService\'
)
$script:UpdateServices = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'sedsvc')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','ACTION','DRY')][string]$Level = 'INFO')
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'WARN' {'Yellow'} 'ERROR' {'Red'} 'ACTION' {'Green'} 'DRY' {'DarkYellow'} default {'Gray'} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue
}

function Invoke-Action {
    param([string]$Description, [scriptblock]$Action)
    if ($WhatIf) { Write-Log "WOULD: $Description" 'DRY'; return }
    try {
        $ErrorActionPreference = 'Stop'   # non-terminating errors must not be logged as success
        & $Action | Out-Null
        Write-Log $Description 'ACTION'
    } catch {
        Write-Log "FAILED: $Description -- $($_.Exception.Message)" 'ERROR'
    }
}

# Run a native command; throw on non-zero exit code, return its output as text.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $eap
    }
    if ($code -ne 0) { throw "$Exe $($Arguments -join ' ') failed (exit $code): $($out -join ' ')" }
    return ($out -join "`n")
}

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-UserPath {
    param([string]$SubPath)
    if ($SubPath) { return "$($script:UserRoot)\$SubPath" }
    return $script:UserRoot
}

function Confirm-Step {
    param([string]$Prompt)
    if ($Unattended) { return $false }
    $a = Read-Host "$Prompt [y/N]"
    return ($a -match '^(y|yes|j|ja)$')
}

function Get-TaskUserName {
    if ($KioskUser) {
        if ($KioskUser -match '[\\@]') { return $KioskUser }
        return "$env:COMPUTERNAME\$KioskUser"
    }
    if ($AutoLogonUserName) {
        if ($AutoLogonDomain) { return "$AutoLogonDomain\$AutoLogonUserName" }
        return "$env:COMPUTERNAME\$AutoLogonUserName"
    }
    return "$env:USERDOMAIN\$env:USERNAME"
}

# Stop + disable a service. Some update services are protected by Windows: warn instead of failing;
# the update-guard task keeps retrying.
function Disable-ServiceBestEffort {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
    } catch {
        & sc.exe config $Name start= disabled | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Service $Name is protected by Windows and could not be disabled (update guard will retry)." 'WARN'
        }
    }
}

function Disable-TasksUnder {
    param([string[]]$Paths)
    $done = 0; $protected = 0
    foreach ($p in $Paths) {
        foreach ($t in @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)) {
            if ($t.State -eq 'Disabled') { continue }
            try { $t | Disable-ScheduledTask -ErrorAction Stop | Out-Null; $done++ } catch { $protected++ }
        }
    }
    Write-Log "Disabled $done task(s) under $($Paths -join ', '); $protected protected by Windows (update guard retries)." 'INFO'
}

# Point all per-user (HKCU) writes at the kiosk account instead of the elevated admin.
function Initialize-UserHive {
    if (-not $KioskUser) {
        Write-Log "No -KioskUser given: per-user (HKCU) tweaks apply to $env:USERDOMAIN\$env:USERNAME. If you elevated from a different account, pass -KioskUser." 'WARN'
        return
    }
    try {
        $nt  = New-Object System.Security.Principal.NTAccount($KioskUser)
        $sid = $nt.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        Write-Log "Could not resolve -KioskUser '$KioskUser': $($_.Exception.Message). Falling back to HKCU." 'WARN'
        return
    }
    if (Test-Path "Registry::HKEY_USERS\$sid") {
        $script:UserRoot   = "Registry::HKEY_USERS\$sid"
        $script:UserRegKey = "HKU\$sid"
        Write-Log "Per-user tweaks target $KioskUser (hive already loaded)." 'INFO'
        return
    }
    $prof = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
    if (-not $prof) {
        Write-Log "User '$KioskUser' has no profile yet (never logged on). Log in once, then re-run. Falling back to HKCU." 'WARN'
        return
    }
    if ($WhatIf) { Write-Log "WOULD: load $($prof.LocalPath)\NTUSER.DAT for per-user tweaks" 'DRY'; return }
    $hive = Join-Path $prof.LocalPath 'NTUSER.DAT'
    reg.exe load HKU\PlayoutKiosk "$hive" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $script:UserRoot   = 'Registry::HKEY_USERS\PlayoutKiosk'
        $script:UserRegKey = 'HKU\PlayoutKiosk'
        $script:HiveLoaded = $true
        Write-Log "Loaded hive of $KioskUser for per-user tweaks." 'INFO'
    } else {
        Write-Log "Could not load hive for $KioskUser. Falling back to HKCU." 'WARN'
    }
}

function Dismount-UserHive {
    if ($script:HiveLoaded) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        reg.exe unload HKU\PlayoutKiosk 2>&1 | Out-Null
        $script:HiveLoaded = $false
    }
}

function New-SafetyBackup {
    if ($script:BackupDone) { return }
    $script:BackupDone = $true
    if ($WhatIf) { Write-Log "WOULD: create restore point and export touched registry keys" 'DRY'; return }
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $srKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        $srName = 'SystemRestorePointCreationFrequency'
        $prev   = (Get-ItemProperty -LiteralPath $srKey -Name $srName -ErrorAction SilentlyContinue).$srName
        Set-Reg $srKey $srName 0
        try {
            Checkpoint-Computer -Description "Playout-Prep $($script:Stamp)" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Write-Log "System restore point created." 'INFO'
        } finally {
            if ($null -ne $prev) { Set-Reg $srKey $srName $prev }
            else { Remove-ItemProperty -LiteralPath $srKey -Name $srName -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Log "Restore point not created: $($_.Exception.Message)" 'WARN'
    }
    $dir = Join-Path $env:SystemDrive "Playout-Prep-Backup-$($script:Stamp)"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $ur = $script:UserRegKey
    $keys = @(
        'HKLM\SOFTWARE\Policies',
        'HKLM\SYSTEM\CurrentControlSet\Control\Power',
        'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel',
        'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers',
        'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl',
        'HKLM\SOFTWARE\Microsoft\Windows\Dwm',
        'HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting',
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
        "$ur\Software\Policies",
        "$ur\Software\Microsoft\DirectX",
        "$ur\Control Panel\Accessibility",
        "$ur\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    )
    foreach ($k in $keys) {
        $file = Join-Path $dir (($k -replace '[\\: ]', '_') + '.reg')
        reg.exe export $k $file /y 2>&1 | Out-Null
    }
    Write-Log "Registry exports saved to $dir" 'INFO'
}

# ---------------------------------------------------------------------------
# 2. Power
# ---------------------------------------------------------------------------
function Invoke-Power {
    Write-Log "== Power, sleep and throttling ==" 'INFO'

    Invoke-Action "Create/activate '24-7 Playout' plan (AC+DC: no sleep/hibernate/display/disk timeouts, CPU 100%, no core parking, PCIe ASPM off, USB selective suspend off, no password on wake)" {
        $g = $null
        $existing = powercfg.exe /list | Select-String '24-7 Playout' | Select-Object -First 1
        if ($existing -and ($existing.Line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')) {
            $g = $Matches[1]
        } else {
            $out = Invoke-Native powercfg.exe @('/duplicatescheme', 'SCHEME_MIN')
            if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                $g = $Matches[1]
            } else {
                throw "powercfg /duplicatescheme returned no GUID: $out"
            }
            Invoke-Native powercfg.exe @('/changename', $g, '24-7 Playout', 'Always-on media playout') | Out-Null
        }
        $settings = @(
            @('SUB_SLEEP',     'STANDBYIDLE',      0),
            @('SUB_SLEEP',     'HIBERNATEIDLE',    0),
            @('SUB_VIDEO',     'VIDEOIDLE',        0),
            @('SUB_DISK',      'DISKIDLE',         0),
            @('SUB_PROCESSOR', 'PROCTHROTTLEMIN',  100),
            @('SUB_PROCESSOR', 'PROCTHROTTLEMAX',  100),
            @('SUB_PROCESSOR', 'CPMINCORES',       100),
            @('SUB_PCIEXPRESS','ASPM',             0),
            @('SUB_NONE',      'CONSOLELOCK',      0),
            @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0)
        )
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        foreach ($s in $settings) {
            foreach ($mode in '/setacvalueindex', '/setdcvalueindex') {
                & powercfg.exe $mode $g $s[0] $s[1] $s[2] 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Log "powercfg $mode $($s[0])/$($s[1]) not supported on this system (skipped)" 'WARN' }
            }
        }
        $ErrorActionPreference = $eap
        Invoke-Native powercfg.exe @('/setactive', $g) | Out-Null
        $active = Invoke-Native powercfg.exe @('/getactivescheme')
        if ($active -notmatch [regex]::Escape($g)) { throw "Power plan $g did not become active" }
    }
    Invoke-Action "Disable hibernation (removes hiberfil.sys and Fast Startup)" { Invoke-Native powercfg.exe @('/hibernate', 'off') | Out-Null }
    Invoke-Action "Disable Fast Startup explicitly" {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    }
    Invoke-Action "Turn off Power Throttling / EcoQoS (background or occluded processes keep full speed)" {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
    }
    if ($script:IsWin11) {
        Invoke-Action "Honour timer-resolution requests from occluded/background processes (Windows 11 ignores them by default)" {
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1
        }
    }
}

# ---------------------------------------------------------------------------
# 15. vvvv prerequisites (must run BEFORE the Windows Update lock)
# ---------------------------------------------------------------------------
function Get-DotNetState {
    $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (-not (Test-Path $dotnet)) {
        $cmd = Get-Command dotnet.exe -ErrorAction SilentlyContinue
        if ($cmd) { $dotnet = $cmd.Source } else { $dotnet = $null }
    }
    $state = @{ Path = $dotnet; Sdks = @(); Runtimes = @() }
    if ($dotnet) {
        $state.Sdks     = @(& $dotnet --list-sdks 2>$null)
        $state.Runtimes = @(& $dotnet --list-runtimes 2>$null)
    }
    return $state
}

function Test-VcRedist {
    $p = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    return ((Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue).Installed -eq 1)
}

function Test-DotNetPresent {
    $st    = Get-DotNetState
    $major = [regex]::Escape($DotNetMajor)
    $sdk   = (@($st.Sdks | Where-Object { $_ -match "^$major\." }).Count -gt 0)
    if ($DotNetKind -eq 'SDK') { return $sdk }
    if ($sdk) { return $true }   # the SDK installs the runtimes as well
    $pattern = "^Microsoft\.NETCore\.App $major\."
    if ($DotNetKind -eq 'DesktopRuntime') { $pattern = "^Microsoft\.WindowsDesktop\.App $major\." }
    return (@($st.Runtimes | Where-Object { $_ -match $pattern }).Count -gt 0)
}

function Invoke-Prerequisites {
    Write-Log "== vvvv prerequisites (VC++ Redistributable + .NET $DotNetMajor $DotNetKind) ==" 'INFO'
    $needVc  = -not (Test-VcRedist)
    $needNet = -not (Test-DotNetPresent)
    if (-not $needVc -and -not $needNet) {
        Write-Log "VC++ 2015-2022 Redistributable (x64) and .NET $DotNetMajor $DotNetKind are already present." 'INFO'
        return
    }
    if ($needVc)  { Write-Log "Missing: Visual C++ 2015-2022 Redistributable (x64)" 'WARN' }
    if ($needNet) { Write-Log "Missing: .NET $DotNetMajor $DotNetKind" 'WARN' }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Log "winget (App Installer) not available for this account. Install the missing items manually from Microsoft BEFORE blocking Windows Update; the gray book 'Exporting Applications' page lists what your vvvv version needs." 'WARN'
        return
    }
    if (-not ($InstallPrerequisites -or (Confirm-Step "Install the missing prerequisites via winget now (needs internet)?"))) {
        Write-Log "Prerequisites NOT installed. Install them before the Windows Update lock / before going live." 'WARN'
        return
    }
    $items = @()
    if ($needVc)  { $items += 'Microsoft.VCRedist.2015+.x64' }
    if ($needNet) { $items += "Microsoft.DotNet.$DotNetKind.$DotNetMajor" }
    foreach ($id in $items) {
        Invoke-Action "winget install $id (silent)" {
            Invoke-Native winget.exe @('install', '--id', $id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements') | Out-Null
        }
    }
    if (-not $WhatIf) {
        if (-not (Test-VcRedist))      { Write-Log "VC++ Redistributable still not detected after install." 'WARN' }
        if (-not (Test-DotNetPresent)) { Write-Log ".NET $DotNetMajor $DotNetKind still not detected after install." 'WARN' }
    }
}

function Show-PrerequisiteState {
    $st = Get-DotNetState
    Write-Host ("VC++ 2015-2022 x64  : " + (Test-VcRedist))
    Write-Host (".NET $DotNetMajor $DotNetKind present : " + (Test-DotNetPresent))
    Write-Host ("dotnet SDKs         : " + ((@($st.Sdks) | ForEach-Object { ($_ -split ' ')[0] }) -join ', '))
}

# ---------------------------------------------------------------------------
# 3. Windows Update
# ---------------------------------------------------------------------------
function Install-UpdateGuard {
    $dir  = Join-Path $env:ProgramData 'PlayoutPrep'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $file = Join-Path $dir 'Update-Guard.ps1'
    $body = @'
$ErrorActionPreference = 'SilentlyContinue'
# Re-apply the Windows Update lock (Windows remediation tasks may re-enable services/tasks).
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
New-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
foreach ($s in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'sedsvc') {
    $svc = Get-Service -Name $s
    if ($svc) {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $s -Force }
        if ($svc.StartType -ne 'Disabled') { Set-Service -Name $s -StartupType Disabled }
    }
}
foreach ($p in '\Microsoft\Windows\UpdateOrchestrator\', '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\WaaSMedic\') {
    Get-ScheduledTask -TaskPath $p | Where-Object { $_.State -ne 'Disabled' } | Disable-ScheduledTask | Out-Null
}
'@
    Set-Content -Path $file -Value $body -Encoding ASCII
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $file)
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $rep       = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
    $trigger.Repetition = $rep.Repetition
    $settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
                    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'Playout-UpdateGuard' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
}

function Invoke-Updates {
    $mode = 'BLOCKED'
    if ($AllowUpdates) { $mode = 'NOTIFY-ONLY (-AllowUpdates)' }
    Write-Log "== Windows Update: $mode ==" 'INFO'
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = "$wu\AU"

    Invoke-Action "Exclude drivers from Windows Update (keeps the GPU/NIC drivers you installed)" {
        Set-Reg $wu 'ExcludeWUDriversInQualityUpdate' 1
    }
    Invoke-Action "Defer feature updates 365 days and quality updates 30 days" {
        Set-Reg $wu 'DeferFeatureUpdates' 1
        Set-Reg $wu 'DeferFeatureUpdatesPeriodInDays' 365
        Set-Reg $wu 'DeferQualityUpdates' 1
        Set-Reg $wu 'DeferQualityUpdatesPeriodInDays' 30
    }
    if ($TargetRelease) {
        Invoke-Action "Pin feature release to $TargetRelease" {
            $product = 'Windows 10'
            if ($script:IsWin11) { $product = 'Windows 11' }
            Set-Reg $wu 'TargetReleaseVersion' 1
            Set-Reg $wu 'TargetReleaseVersionInfo' $TargetRelease 'String'
            Set-Reg $wu 'ProductVersion' $product 'String'
        }
    }
    Invoke-Action "Block upgrade offers to a newer Windows version" {
        Set-Reg $wu 'DisableOSUpgrade' 1
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\OSUpgrade' 'ReservationsAllowed' 0
    }
    Invoke-Action "Never auto-reboot with a user logged on, no restart nags, no 'sign in and lock after restart'" {
        Set-Reg $au 'NoAutoRebootWithLoggedOnUsers' 1
        Set-Reg $au 'SetAutoRestartNotificationDisable' 1
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableAutomaticRestartSignOn' 1
    }
    Invoke-Action "Delivery Optimization: HTTP only, no peering; Store apps: no auto-updates" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
    }

    if ($AllowUpdates) {
        Invoke-Action "Notify-only updates (AUOptions=2), update UI visible, guard task removed" {
            Set-Reg $au 'NoAutoUpdate' 0
            Set-Reg $au 'AUOptions' 2
            Set-Reg $wu 'SetDisableUXWUAccess' 0
            Unregister-ScheduledTask -TaskName 'Playout-UpdateGuard' -Confirm:$false -ErrorAction SilentlyContinue
        }
        return
    }

    Invoke-Action "BLOCK: automatic updates off by policy, Windows Update settings page hidden" {
        Set-Reg $au 'NoAutoUpdate' 1
        Set-Reg $wu 'SetDisableUXWUAccess' 1
    }
    Invoke-Action "BLOCK: stop and disable Windows Update services ($($script:UpdateServices -join ', '))" {
        foreach ($s in $script:UpdateServices) { Disable-ServiceBestEffort $s }
    }
    Invoke-Action "BLOCK: disable update / orchestrator / remediation scheduled tasks" {
        Disable-TasksUnder $script:UpdateTaskPaths
    }
    Invoke-Action "BLOCK: install SYSTEM task 'Playout-UpdateGuard' (at startup + every 30 min, hidden) that re-applies the block if Windows re-enables anything" {
        Install-UpdateGuard
    }
}

# Menu 14: deliberately open a maintenance window. Re-run section 3 afterwards to lock again.
function Invoke-UpdateUnlock {
    Write-Log "== Unlock Windows Update for a maintenance window ==" 'INFO'
    Invoke-Action "Remove update guard task" {
        Unregister-ScheduledTask -TaskName 'Playout-UpdateGuard' -Confirm:$false -ErrorAction SilentlyContinue
    }
    Invoke-Action "Policies: automatic updates allowed (notify), update UI visible" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'SetDisableUXWUAccess' 0
    }
    Invoke-Action "Services back to Manual (wuauserv, UsoSvc, DoSvc, WaaSMedicSvc where permitted) and update tasks re-enabled" {
        foreach ($s in $script:UpdateServices) {
            if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
                try { Set-Service -Name $s -StartupType Manual -ErrorAction Stop } catch { Write-Log "Could not change $s (protected)." 'WARN' }
            }
        }
        foreach ($p in $script:UpdateTaskPaths) {
            foreach ($t in @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)) {
                try { $t | Enable-ScheduledTask -ErrorAction Stop | Out-Null } catch { }
            }
        }
    }
    Write-Log "Windows Update is open. Patch, reboot, then run menu 3 to lock it again BEFORE going live." 'WARN'
}

# ---------------------------------------------------------------------------
# 4. Graphics
# ---------------------------------------------------------------------------
function Invoke-Graphics {
    Write-Log "== Graphics / GPU-related OS settings ==" 'INFO'

    Invoke-Action "Disable Game DVR / Game Bar capture hooks" {
        Set-Reg (Get-UserPath 'System\GameConfigStore') 'GameDVR_Enabled' 0
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\GameDVR') 'AppCaptureEnabled' 0
        Set-Reg (Get-UserPath 'Software\Microsoft\GameBar') 'UseNexusForGameBarEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    }
    Invoke-Action "Turn off 'Optimizations for windowed games' (stops Windows silently upgrading the app's swap-chain presentation model)" {
        Set-Reg (Get-UserPath 'Software\Microsoft\DirectX\UserGpuPreferences') 'DirectXUserGlobalSettings' 'SwapEffectUpgradeEnable=0;' 'String'
    }
    if ($HAGS -ne 'Leave') {
        if ($script:Build -ge 19041) {
            Invoke-Action "Set Hardware-accelerated GPU scheduling = $HAGS (reboot required)" {
                $v = 1
                if ($HAGS -eq 'On') { $v = 2 }
                Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' $v
            }
        } else {
            Write-Log "HAGS needs Windows 10 2004 or newer: skipped." 'WARN'
        }
    }
    if ($DisableMPO) {
        Invoke-Action "Disable Multiplane Overlay in DWM (workaround for flicker/black frames; reboot required)" {
            Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5
        }
    }
    if ($AppPath) {
        Invoke-Action "Per-app: GPU preference = High performance and fullscreen optimizations off for $AppPath" {
            Set-Reg (Get-UserPath 'Software\Microsoft\DirectX\UserGpuPreferences') $AppPath 'GpuPreference=2;' 'String'
            Set-Reg (Get-UserPath 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers') $AppPath '~ DISABLEDXMAXIMIZEDWINDOWEDMODE' 'String'
        }
    } else {
        Write-Log "-AppPath not set: skipping per-app GPU preference / fullscreen-optimization flags." 'WARN'
    }
}

# ---------------------------------------------------------------------------
# 5. Distractions
# ---------------------------------------------------------------------------
function Invoke-Distractions {
    Write-Log "== Focus-stealing popups, notifications, lock screen, prompts ==" 'INFO'

    Invoke-Action "Disable Sticky/Filter/Toggle Keys hotkeys and popups (kiosk user + logon screen)" {
        foreach ($root in @($script:UserRoot, 'Registry::HKEY_USERS\.DEFAULT')) {
            Set-Reg "$root\Control Panel\Accessibility\StickyKeys"        'Flags' '506' 'String'
            Set-Reg "$root\Control Panel\Accessibility\Keyboard Response" 'Flags' '122' 'String'
            Set-Reg "$root\Control Panel\Accessibility\ToggleKeys"        'Flags' '58'  'String'
        }
    }
    Invoke-Action "Disable toast notifications, notification center banners and Defender notifications" {
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\PushNotifications') 'ToastEnabled' 0
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings') 'NOC_GLOBAL_SETTING_TOASTS_ENABLED' 0
        Set-Reg (Get-UserPath 'Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications') 'NoToastApplicationNotification' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableNotifications' 1
    }
    Invoke-Action "Disable lock screen and screensaver" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1
        Set-Reg (Get-UserPath 'Control Panel\Desktop') 'ScreenSaveActive' '0' 'String'
        Set-Reg (Get-UserPath 'Software\Policies\Microsoft\Windows\Control Panel\Desktop') 'ScreenSaveActive' '0' 'String'
    }
    Invoke-Action "Disable AutoPlay/AutoRun (USB sticks for content updates must not pop a dialog over the output)" {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers') 'DisableAutoplay' 1
    }
    Invoke-Action "Third-party apps: no SmartScreen prompts and no 'Open File - Security Warning' on copied/downloaded files (security trade-off)" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen' 0
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' 'String'
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SmartScreenEnabled' 0
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\Policies\Attachments') 'SaveZoneInformation' 1
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation' 1
    }
    if ($script:IsWin11) {
        $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
        if ($sac -eq 1 -or $sac -eq 2) {
            Write-Log "Smart App Control is ON/evaluating: it can block unsigned third-party apps. Turn it off in Windows Security > App & browser control (it cannot be re-enabled without reinstalling)." 'WARN'
        }
    }
    Invoke-Action "Suppress the 'allow your PC to be discoverable on this network?' prompt" {
        New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff' -Force | Out-Null
    }
    Invoke-Action "Do not reopen apps after restart (RestartApps off for the kiosk user)" {
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon') 'RestartApps' 0
    }
    Invoke-Action "Disable ads, suggestions, tips, welcome experience and consumer content" {
        $cdm = Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        foreach ($n in 'ContentDeliveryAllowed','OemPreInstalledAppsEnabled','PreInstalledAppsEnabled','PreInstalledAppsEverEnabled',
                       'SilentInstalledAppsEnabled','SoftLandingEnabled','SystemPaneSuggestionsEnabled','RotatingLockScreenEnabled',
                       'RotatingLockScreenOverlayEnabled','SubscribedContent-310093Enabled','SubscribedContent-338387Enabled',
                       'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-353694Enabled',
                       'SubscribedContent-353696Enabled') {
            Set-Reg $cdm $n 0
        }
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement') 'ScoobeSystemSettingEnabled' 0
        $cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        Set-Reg $cc 'DisableWindowsConsumerFeatures' 1
        Set-Reg $cc 'DisableSoftLanding' 1
        Set-Reg $cc 'DisableWindowsSpotlightFeatures' 1
        Set-Reg $cc 'DisableCloudOptimizedContent' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1
    }
    Invoke-Action "Disable Widgets / News and Interests, Copilot and clipboard-history panel" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
        Set-Reg (Get-UserPath 'Software\Policies\Microsoft\Windows\WindowsCopilot') 'TurnOffWindowsCopilot' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0
    }
}

# ---------------------------------------------------------------------------
# 6. Background services, tasks, Defender, Edge
# ---------------------------------------------------------------------------
function Invoke-Background {
    Write-Log "== Background tasks, services, maintenance, Defender, Edge ==" 'INFO'

    Invoke-Action "Turn off Automatic Maintenance" {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1
    }
    $tasks = @(
        '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
        '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
        '\Microsoft\Windows\Application Experience\StartupAppTask',
        '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
        '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
        '\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask',
        '\Microsoft\Windows\Windows Error Reporting\QueueReporting',
        '\Microsoft\Windows\Feedback\Siuf\DmClient',
        '\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload',
        '\Microsoft\Windows\TaskScheduler\Idle Maintenance',
        '\Microsoft\Windows\TaskScheduler\Maintenance Configurator',
        '\Microsoft\Windows\TaskScheduler\Regular Maintenance',
        '\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
        '\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
        '\Microsoft\Windows\Maps\MapsUpdateTask',
        '\Microsoft\Windows\Maps\MapsToastTask',
        '\Microsoft\Windows\Shell\FamilySafetyMonitor',
        '\Microsoft\Windows\Shell\FamilySafetyRefreshTask'
    )
    foreach ($t in $tasks) {
        Invoke-Action "Disable scheduled task $t" {
            if ($t -match '^(.*\\)([^\\]+)$') {
                $task = Get-ScheduledTask -TaskPath $Matches[1] -TaskName $Matches[2] -ErrorAction SilentlyContinue
                if ($task) { $task | Disable-ScheduledTask | Out-Null }
            }
        }
    }
    Write-Log "Left untouched on purpose: ScheduledDefrag (it also performs SSD TRIM/retrim; runs weekly when idle)." 'INFO'

    $svcs = @('SysMain', 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'RetailDemo')
    if ($Aggressive) { $svcs += 'WSearch' }
    foreach ($s in $svcs) {
        Invoke-Action "Stop and disable service $s" {
            if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
                Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
                Set-Service -Name $s -StartupType Disabled
            }
        }
    }

    Invoke-Action "Edge: no background updater, no startup boost/background mode, no first-run screens" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'UpdateDefault' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'AutoUpdateCheckPeriodMinutes' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1
        foreach ($t in @(Get-ScheduledTask -TaskName 'MicrosoftEdgeUpdate*' -ErrorAction SilentlyContinue)) {
            $t | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($s in 'edgeupdate', 'edgeupdatem') { Disable-ServiceBestEffort $s }
    }

    Invoke-Action "Defender: no scheduled or catch-up scans, scan CPU capped at 10% (real-time protection stays ON)" {
        Set-MpPreference -ScanScheduleDay 8 -DisableCatchupFullScan $true -DisableCatchupQuickScan $true -ScanAvgCPULoadFactor 10 -ErrorAction Stop
    }

    $paths = @($MediaPaths)
    if ($AppPath) { $paths += (Split-Path $AppPath -Parent) }
    $paths = @($paths | Where-Object { $_ } | Select-Object -Unique)
    if ($paths.Count -gt 0) {
        Invoke-Action "Defender real-time scan exclusions: $($paths -join ', ')$(if ($AppPath) { ' + process ' + (Split-Path $AppPath -Leaf) })" {
            foreach ($p in $paths) { Add-MpPreference -ExclusionPath $p -ErrorAction Stop }
            if ($AppPath) { Add-MpPreference -ExclusionProcess (Split-Path $AppPath -Leaf) -ErrorAction Stop }
        }
    } else {
        Write-Log "No -MediaPaths/-AppPath: no Defender exclusions added." 'INFO'
    }

    if ($Aggressive) {
        Invoke-Action "AGGRESSIVE: disable memory compression (reboot required)" {
            Disable-MMAgent -MemoryCompression -ErrorAction Stop
        }
        Invoke-Action "AGGRESSIVE: disable Memory Integrity (HVCI) and VBS -- measurable overhead, but a real security reduction (reboot required)" {
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
            Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Network and time
# ---------------------------------------------------------------------------
function Invoke-Network {
    Write-Log "== Network and time ==" 'INFO'

    Invoke-Action "Disable 'allow the computer to turn off this device' on physical NICs (restart the adapter or reboot to apply)" {
        $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
        $guids = @(Get-NetAdapter -Physical | Select-Object -ExpandProperty InterfaceGuid)
        foreach ($k in Get-ChildItem $classKey -ErrorAction SilentlyContinue) {
            $id = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).NetCfgInstanceId
            if ($id -and ($guids -contains $id)) { Set-Reg $k.PSPath 'PnPCapabilities' 24 }
        }
    }
    Invoke-Action "Disable Energy-Efficient / Green Ethernet where the driver exposes it" {
        foreach ($a in Get-NetAdapter -Physical) {
            foreach ($prop in 'Energy-Efficient Ethernet', 'Energy Efficient Ethernet', 'Green Ethernet', 'Ultra Low Power Mode') {
                Set-NetAdapterAdvancedProperty -Name $a.Name -DisplayName $prop -DisplayValue 'Disabled' -ErrorAction SilentlyContinue
            }
        }
    }
    if ($SetNetworkPrivate) {
        Invoke-Action "Set connected 'Public' networks to 'Private'" {
            Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' } |
                Set-NetConnectionProfile -NetworkCategory Private
        }
    }
    if ($AppPath) {
        Invoke-Action "Firewall: allow inbound for $AppPath on Private+Domain profiles (OSC/Art-Net/sACN/NDI...)" {
            $n = "Playout: $(Split-Path $AppPath -Leaf)"
            if (-not (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $n -Direction Inbound -Program $AppPath -Action Allow -Profile Private, Domain | Out-Null
            }
        }
    }
    Invoke-Action "Windows Time: automatic start, NTP peers $($NtpServers -join ', '), 15 min poll, resync" {
        Set-Service w32time -StartupType Automatic
        if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time }
        $peerArg = "/manualpeerlist:" + (($NtpServers | ForEach-Object { "$_,0x9" }) -join ' ')
        Invoke-Native w32tm.exe @('/config', $peerArg, '/syncfromflags:manual', '/reliable:NO', '/update') | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient' 'SpecialPollInterval' 900
        Restart-Service w32time
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        w32tm.exe /resync /force 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "w32tm resync failed (peer not reachable yet?); it will sync later" 'WARN' }
        $ErrorActionPreference = $eap
    }
}

# ---------------------------------------------------------------------------
# 8. Debloat (conservative)
# ---------------------------------------------------------------------------
function Invoke-Debloat {
    Write-Log "== Debloat (AppX removal is NOT undone by the restore point) ==" 'INFO'

    $protect = @('Microsoft.DesktopAppInstaller', 'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp',
                 'Microsoft.WindowsTerminal', 'Microsoft.WindowsNotepad', 'Microsoft.Paint',
                 'Microsoft.Windows.Photos', 'Microsoft.WindowsCalculator', 'Microsoft.SecHealthUI') + $AppsToKeep
    $remove = @(
        'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
        'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People',
        'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.YourPhone',
        'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Microsoft.PowerAutomateDesktop',
        'Microsoft.XboxApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay',
        'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxIdentityProvider',
        'Microsoft.GamingApp', 'Microsoft.549981C3F5F10', 'Microsoft.windowscommunicationsapps',
        'Microsoft.OutlookForWindows', 'Microsoft.Copilot', 'MicrosoftTeams', 'MSTeams', 'Clipchamp.Clipchamp',
        'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer', 'Microsoft.Print3D',
        'Microsoft.SkypeApp', 'Microsoft.OneConnect', 'Microsoft.Wallet'
    )
    $prov = @()
    if (-not $WhatIf) { $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) }

    foreach ($name in $remove) {
        if ($protect -contains $name) { Write-Log "Keeping $name (protected/kept)" 'INFO'; continue }
        Invoke-Action "Remove AppX $name" {
            Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue |
                Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            $prov | Where-Object { $_.DisplayName -eq $name } |
                Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Invoke-Action "Uninstall OneDrive (system installer, if present) and block file sync by policy; user files are NOT deleted" {
        $setup = Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe'
        if (-not (Test-Path $setup)) { $setup = Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe' }
        if (Test-Path $setup) {
            Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
            Start-Process $setup -ArgumentList '/uninstall' -Wait
        }
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    }
    Invoke-Action "Telemetry to minimum allowed, no advertising ID, no feedback prompts" {
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
    }
}

# ---------------------------------------------------------------------------
# 9. Resilience
# ---------------------------------------------------------------------------
function Invoke-Watchdog {
    if (-not $AppPath) { Write-Log "-AppPath not set: skipping watchdog task." 'WARN'; return }
    if (-not (Test-Path $AppPath)) { Write-Log "AppPath not found: $AppPath -- skipping watchdog task." 'WARN'; return }
    $user = Get-TaskUserName
    if ($RunElevated) { Write-Log "-RunElevated only elevates for administrator accounts; a standard kiosk user's task still runs unelevated." 'WARN' }
    Invoke-Action "Watchdog task 'Playout-Watchdog': launches $AppPath at logon of $user and re-launches it within 1 minute if it exits or crashes (no duplicate instances)" {
        $actionArgs = @{ Execute = $AppPath; WorkingDirectory = (Split-Path $AppPath -Parent) }
        if ($AppArguments) { $actionArgs['Argument'] = $AppArguments }
        $action  = New-ScheduledTaskAction @actionArgs
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $rep     = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
        $trigger.Repetition = $rep.Repetition
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        $runLevel = 'Limited'
        if ($RunElevated) { $runLevel = 'Highest' }
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $runLevel
        Register-ScheduledTask -TaskName 'Playout-Watchdog' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    }
}

function Invoke-Resilience {
    Write-Log "== Resilience ==" 'INFO'
    Invoke-Action "Crash handling: auto-reboot after BSOD, small memory dump" {
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'AutoReboot' 1
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled' 3
    }
    Invoke-Action "Suppress Windows Error Reporting crash dialogs (a crashed app must actually exit so the watchdog can relaunch it)" {
        Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'DontShowUI' 1
        Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'DontShowUI' 1
        Set-Reg (Get-UserPath 'Software\Microsoft\Windows\Windows Error Reporting') 'DontShowUI' 1
    }
    if ($AppPath) {
        Invoke-Action "Crash dumps: keep up to 3 full dumps of $(Split-Path $AppPath -Leaf) in $($env:SystemDrive)\CrashDumps (WER LocalDumps)" {
            $dumpDir = Join-Path $env:SystemDrive 'CrashDumps'
            New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null
            $k = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\' + (Split-Path $AppPath -Leaf)
            Set-Reg $k 'DumpFolder' $dumpDir 'ExpandString'
            Set-Reg $k 'DumpCount' 3
            Set-Reg $k 'DumpType' 2
        }
    }
    Invoke-Watchdog
    if ($DailyRebootTime) {
        Invoke-Action "Daily maintenance reboot at $DailyRebootTime (task 'Playout-DailyReboot', SYSTEM, 60 s warning)" {
            $action    = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/r /t 60 /c "Scheduled playout maintenance reboot"'
            $trigger   = New-ScheduledTaskTrigger -Daily -At $DailyRebootTime
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName 'Playout-DailyReboot' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Auto-logon (not part of "Run all")
# ---------------------------------------------------------------------------
function Invoke-AutoLogon {
    Write-Log "== Auto-logon ==" 'INFO'
    if ($WhatIf) { Write-Log "WOULD: configure auto-logon using method '$AutoLogonMethod'" 'DRY'; return }

    $user = $AutoLogonUserName
    if (-not $user) { $user = Read-Host "Auto-logon user name (use a dedicated low-privilege account)" }
    $dom = $AutoLogonDomain
    if (-not $dom) { $dom = $env:COMPUTERNAME }
    $pw = $AutoLogonPassword
    if (-not $pw) { $pw = Read-Host "Password for $user" -AsSecureString }
    $plain = [System.Net.NetworkCredential]::new('', $pw).Password

    try {
        if ($AutoLogonMethod -eq 'Sysinternals') {
            if (-not $AutologonExePath -or -not (Test-Path $AutologonExePath)) {
                throw "-AutologonExePath must point to a downloaded Autologon64.exe (or use -AutoLogonMethod Registry)"
            }
            & $AutologonExePath $user $dom $plain /accepteula | Out-Null
            Write-Log "Auto-logon configured for $dom\$user via Sysinternals Autologon (encrypted LSA secret)." 'ACTION'
        } else {
            $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-Reg $wl 'AutoAdminLogon'    '1'   'String'
            Set-Reg $wl 'DefaultUserName'   $user 'String'
            Set-Reg $wl 'DefaultDomainName' $dom  'String'
            Set-Reg $wl 'DefaultPassword'   $plain 'String'
            Write-Log "Auto-logon configured for $dom\$user via Winlogon registry (password stored in PLAINTEXT)." 'ACTION'
        }
    } catch {
        Write-Log "FAILED: auto-logon -- $($_.Exception.Message)" 'ERROR'
    } finally {
        $plain = $null
    }
}

# ---------------------------------------------------------------------------
# 11. Checklist
# ---------------------------------------------------------------------------
function Show-Checklist {
    Write-Host @'

 Fresh-install checklist
 -----------------------
 Order
   1. Install Windows, run ONE final patch cycle, reboot until nothing is pending.
   2. Install GPU / chipset / NIC drivers, then vvvv prerequisites (menu 15) BEFORE the update lock.
   3. Run this script (-WhatIf first), reboot.
   4. Install player software and content, test, image the machine.
   5. Maintenance later: menu 14 (unlock updates) -> patch -> reboot -> menu 3 (lock again).

 Windows edition / support
   * Use Pro, Enterprise or IoT Enterprise LTSC. Home ignores many of the policies used here.
   * Windows 10 no longer receives security updates without ESU; for new installs prefer
     Windows 11 or LTSC. With updates blocked, keep playout machines on an isolated network.
   * With Windows Update blocked: Store installs, winget msstore sources and feature-on-demand
     installs (e.g. .NET Framework 3.5) fail until you unlock (menu 14). Defender definitions
     stop updating; schedule a maintenance window or import definitions manually.
   * Smart App Control (Win11 fresh installs) must be switched off manually in Windows Security.
   * If you want Defender fully off, Tamper Protection must be turned off by hand first.

 GPU (NVIDIA)
   * Install the NVIDIA RTX Enterprise / Production Branch driver (not Game Ready), clean install.
   * NVIDIA Control Panel > Manage 3D settings > Power management mode: Prefer maximum performance.
   * Set every output's resolution/refresh rate explicitly; use an EDID emulator on outputs that
     can go dark (projector standby, hot-plug) so the desktop layout never collapses.
   * If you use Mosaic/Sync, configure it before first launching the show.

 BIOS/UEFI
   * Restore on AC power loss = Power On.
   * PCIe ASPM = Off; if you see frame-pacing hiccups, limit deep CPU C-states.
   * Disable onboard devices you don't use (audio/Wi-Fi/Bluetooth).

 vvvv
   * Run the EXPORTED app on playout machines, not the editor, and test it as the kiosk user on the
     final output layout.
   * Exports that reference VL.Stride need the VC++ Redistributable and .NET on the target PC; check the
     gray book 'Exporting Applications' page for your vvvv version (menu 15 checks/installs).
   * Editor packages live per user under %LOCALAPPDATA%\vvvv\gamma\nugets.
   * Set display scaling to 100% on the playout displays and test (DPI behaviour not verified).
   * Use the windowing mode you will run in production when judging frame pacing; then decide on
     -HAGS On/Off and -DisableMPO empirically.

 Validation
   * Reboot, let the watchdog start the app, kill the process once and confirm it returns
     within ~1 minute. Menu 13 shows the current state.
   * Soak test 24-48 h; watch `nvidia-smi dmon` and the Windows Reliability Monitor.

'@ -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 13. Verification
# ---------------------------------------------------------------------------
function Show-Verification {
    Write-Host "`n== Current state ($($script:OsLabel)) ==" -ForegroundColor Cyan
    Write-Host ("Active power plan   : " + ((powercfg.exe /getactivescheme) -join ' '))
    $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction SilentlyContinue).HibernateEnabled
    Write-Host "HibernateEnabled    : $hib (0 = off)"
    $noAu = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue).NoAutoUpdate
    $wuDrv = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
    Write-Host "NoAutoUpdate policy : $noAu (1 = blocked)    WU driver exclusion: $wuDrv (1 = on)"
    $maint = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' -ErrorAction SilentlyContinue).MaintenanceDisabled
    Write-Host "Auto maintenance off: $maint (1 = off)"
    foreach ($tn in 'Playout-UpdateGuard', 'Playout-Watchdog', 'Playout-DailyReboot') {
        $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if ($t) { Write-Host "Task $tn : $($t.State)" } else { Write-Host "Task $tn : not present" }
    }
    foreach ($s in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'DoSvc', 'SysMain', 'DiagTrack', 'w32time') {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) { Write-Host ("Service {0,-13}: {1} / {2}" -f $s, $svc.Status, $svc.StartType) }
    }
    if ($script:IsWin11) {
        $sac = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
        Write-Host "Smart App Control   : $sac (0 = off, 1 = on, 2 = evaluation)"
    }
    Show-PrerequisiteState
    if ($AppPath) {
        $pn = [System.IO.Path]::GetFileNameWithoutExtension($AppPath)
        Write-Host ("App running ($pn) : " + [bool](Get-Process -Name $pn -ErrorAction SilentlyContinue))
    }
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
function Invoke-All {
    New-SafetyBackup
    Invoke-Power
    Invoke-Prerequisites
    Invoke-Updates
    Invoke-Graphics
    Invoke-Distractions
    Invoke-Background
    Invoke-Network
    if ($IncludeDebloat -or (Confirm-Step "Also run debloat (AppX removal, OneDrive)? This is NOT covered by the restore point")) { Invoke-Debloat }
    Invoke-Resilience
    Write-Log "All sections complete. Auto-logon (10) is separate. Reboot before going live." 'INFO'
}

function Show-Menu {
    Clear-Host
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host " Uninterrupted playout prep - Windows 10/11 ($($script:OsLabel))" -ForegroundColor Cyan
    if ($WhatIf)        { Write-Host " Mode: DRY RUN (-WhatIf) - nothing will change" -ForegroundColor Yellow }
    if ($AllowUpdates)  { Write-Host " Mode: updates NOTIFY-ONLY (-AllowUpdates)" -ForegroundColor Yellow }
    if ($Aggressive)    { Write-Host " Mode: AGGRESSIVE - dedicated/isolated machines only" -ForegroundColor Yellow }
    Write-Host " App: $(if ($AppPath) { $AppPath } else { '(none - pass -AppPath)' })   Kiosk user: $(if ($KioskUser) { $KioskUser } else { '(current user)' })"
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "  1) Run ALL (except auto-logon; debloat asks first)"
    Write-Host "  2) Power and sleep"
    Write-Host "  3) Windows Update: BLOCK (lock)"
    Write-Host "  4) Graphics / GPU-related OS settings"
    Write-Host "  5) Distractions (popups, notifications, lock screen, prompts)"
    Write-Host "  6) Background tasks/services, maintenance, Defender, Edge"
    Write-Host "  7) Network and time"
    Write-Host "  8) Debloat (AppX, OneDrive, telemetry)"
    Write-Host "  9) Resilience (crash dialogs, watchdog, daily reboot)"
    Write-Host " 10) Auto-logon"
    Write-Host " 11) Fresh-install checklist"
    Write-Host " 12) Show log file location"
    Write-Host " 13) Verify current state"
    Write-Host " 14) UNLOCK Windows Update for a maintenance window"
    Write-Host " 15) vvvv prerequisites (VC++ / .NET check + winget install)"
    Write-Host "  0) Exit"
    Write-Host "=============================================================" -ForegroundColor Cyan
}

Write-Log "Session start. $($script:OsLabel). Log: $($script:LogFile)" 'INFO'
if ($script:OsInfo.Caption -match 'Home') {
    Write-Log "Windows Home detected: many policy-based settings are ignored on Home. Use Pro/Enterprise/LTSC for a playout machine." 'WARN'
}
Initialize-UserHive

if ($Unattended) {
    New-SafetyBackup
    Invoke-All
    if ($AutoLogonUserName -and $AutoLogonPassword) { Invoke-AutoLogon }
    Show-Verification
    Write-Log "Unattended run finished with $($script:ErrorCount) error(s). Reboot before going live." 'INFO'
    Dismount-UserHive
    if ($script:ErrorCount -gt 0) { exit 1 }
    exit 0
}

do {
    Show-Menu
    $choice = Read-Host "Select"
    switch ($choice) {
        '1'  { Invoke-All }
        '2'  { New-SafetyBackup; Invoke-Power }
        '3'  { New-SafetyBackup; Invoke-Updates }
        '4'  { New-SafetyBackup; Invoke-Graphics }
        '5'  { New-SafetyBackup; Invoke-Distractions }
        '6'  { New-SafetyBackup; Invoke-Background }
        '7'  { New-SafetyBackup; Invoke-Network }
        '8'  { if (Confirm-Step "Run debloat? AppX removal is NOT covered by the restore point") { New-SafetyBackup; Invoke-Debloat } }
        '9'  { New-SafetyBackup; Invoke-Resilience }
        '10' { if (Confirm-Step "Configure auto-logon? This stores a credential on this machine") { New-SafetyBackup; Invoke-AutoLogon } }
        '11' { Show-Checklist }
        '12' { Write-Host "Log file: $($script:LogFile)" -ForegroundColor Cyan }
        '13' { Show-Verification }
        '14' { New-SafetyBackup; Invoke-UpdateUnlock }
        '15' { Invoke-Prerequisites }
        '0'  { Write-Log "Session ended by user." 'INFO' }
        default { Write-Host "Invalid selection." -ForegroundColor Yellow }
    }
    if ($choice -ne '0') { Read-Host "Press Enter to return to the menu" | Out-Null }
} while ($choice -ne '0')

Dismount-UserHive
